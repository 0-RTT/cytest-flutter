//go:debug tlsmlkem=1

package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
	"crypto/tls"
	"crypto/x509"
	"encoding/csv"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type Config struct {
	TargetSHA1Hash     string `json:"TargetSHA1Hash"`
	MaxSha1Concurrency int    `json:"MaxSha1Concurrency"`

	SpeedTestURL          string `json:"speedTestURL"`
	DialTimeout           int    `json:"dialTimeout"`
	DownloadTimeout       int    `json:"downloadTimeout"`
	MaxLatencyConcurrency int    `json:"maxLatencyConcurrency"`
	MaxSpeedConcurrency   int    `json:"maxSpeedConcurrency"`
	MaxLatency            int64  `json:"maxLatency"`

	HTTPProxy string `json:"httpProxy"`

	Insecure bool `json:"insecure,omitempty"`
}

var (
	cfg      Config
	proxyURL *url.URL

	dataFile    = flag.String("data", "data.txt", "输入：Censys 结果 JSON")
	configFile  = flag.String("config", "config.json", "配置文件路径")
	proxyFlag   = flag.String("proxy", "", "HTTP 代理地址（如 http://127.0.0.1:10810）；优先于配置里的 httpProxy")
	resultCSV   = flag.String("result", "result.csv", "产物：延迟+速度测试结果")
	insecure    = flag.Bool("insecure", false, "关闭 TLS 证书校验（存在中间人风险，慎用）")
	onlyIP      = flag.Bool("only-ip", false, "只做阶段1（SHA1 筛选），匹配结果打印到屏幕，不测速、不写文件")
	onlySpeed   = flag.Bool("only-speed", false, "只做阶段3（速度测试），跳过阶段1 指纹比对与阶段2 延迟测试")
	onlyLatency = flag.Bool("only-latency", false, "只做延迟测试，跳过速度测试")
	targetsFile = flag.String("targets", "", "候选清单；每行 `ip:port` 或 `ip:port,延迟毫秒`，`#` 开头为注释")

	// 带 -targets 且没有 -only-* 时：跑「延迟 + 速度」。
	// 与 -only-speed 的区别是：会先做一轮延迟筛选，只给能连通的 IP 测速。
	topN     = flag.Int("top", 10, "汇总时打印前 N 名")
	quiet    = flag.Bool("quiet", false, "不打印逐条匹配/进度明细")
	selftest = flag.Bool("protocol-selftest", false, "打印各分支的协议样例到 stdout 后退出（供契约测试使用）")
	listOnly = flag.Bool("list", false, "只把 data.txt 里通过服务筛选的候选逐行打印到 stdout，不联网、不写文件")
)

func logf(format string, a ...any) { fmt.Printf(format+"\n", a...) }

type Root struct {
	Results struct {
		Hits []struct {
			Host struct {
				Host struct {
					IP       string `json:"ip"`
					Services []struct {
						Port        int    `json:"port"`
						Protocol    string `json:"protocol"`
						ServiceName string `json:"service_name"`
					} `json:"services"`
				} `json:"host"`
			} `json:"host"`
		} `json:"hits"`
	} `json:"results"`
}

type shaJob struct {
	IP   string
	Port int
	URL  string
}

type dedupSet struct {
	mu sync.Mutex
	m  map[string]struct{}
}

func newDedupSet() *dedupSet { return &dedupSet{m: make(map[string]struct{})} }

func (d *dedupSet) Add(key string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	if _, ok := d.m[key]; ok {
		return false
	}
	d.m[key] = struct{}{}
	return true
}

const (
	maxResponseBytes = 50 * 1024 * 1024
	shaHTTPTimeout   = 5 * time.Second
	retryAttempts    = 1
	progressInterval = 200
)

func selectServices(data []byte) ([]shaJob, bool) {
	dedup := newDedupSet()
	var jobs []shaJob
	broken := false
	for first := 0; first < len(data); {
		open := bytes.IndexByte(data[first:], '{')
		if open < 0 {
			if len(bytes.TrimSpace(data[first:])) > 0 {
				broken = true
			}
			break
		}
		start := first + open
		end := rootEnd(data, start)
		if end < 0 {
			broken = true
			break
		}
		first = end
		var root Root
		if err := json.Unmarshal(data[start:end], &root); err != nil {
			broken = true
			continue
		}
		for _, hit := range root.Results.Hits {
			host := hit.Host.Host
			if host.IP == "" {
				continue
			}
			for _, svc := range host.Services {
				port, ok := servicePort(svc.Protocol, svc.ServiceName, svc.Port)
				if !ok {
					continue
				}
				key := fmt.Sprintf("%s:%d", host.IP, port)
				if !dedup.Add(key) {
					continue
				}
				jobs = append(jobs, shaJob{
					IP:   host.IP,
					Port: port,
					URL:  fmt.Sprintf("http://%s:%d", host.IP, port),
				})
			}
		}
	}
	return jobs, broken
}

func rootEnd(data []byte, start int) int {
	depth := 0
	inString := false
	escaped := false
	for i := start; i < len(data); i++ {
		c := data[i]
		switch {
		case inString:
			if escaped {
				escaped = false
				continue
			}
			if c == '\\' {
				escaped = true
				continue
			}
			if c == '"' {
				inString = false
			}
		case c == '"':
			inString = true
		case c == '{':
			depth++
		case c == '}':
			depth--
			if depth == 0 {
				return i + 1
			}
		}
	}
	return -1
}

func servicePort(protocol, name string, port int) (int, bool) {
	if port < 1 || port > 65535 {
		return 0, false
	}
	if strings.EqualFold(protocol, "HTTP") || (protocol == "" && strings.EqualFold(name, "HTTP")) {
		return port, true
	}
	return 0, false
}

func fetchSHA1(ctx context.Context, client *http.Client, url string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return "", err
	}

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	h := sha1.New()
	if _, err := io.Copy(h, io.LimitReader(resp.Body, maxResponseBytes)); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func runSHA1Filter(ctx context.Context) []*TestResult {
	target := strings.ToLower(strings.TrimSpace(cfg.TargetSHA1Hash))
	if len(target) != 40 {
		fmt.Fprintf(os.Stderr, "TargetSHA1Hash 不合法（应为 40 字符 hex，实际 %d 字符）\n", len(target))
		return nil
	}
	if _, err := hex.DecodeString(target); err != nil {
		fmt.Fprintln(os.Stderr, "TargetSHA1Hash 不是合法的十六进制字符串:", err)
		return nil
	}

	conc := cfg.MaxSha1Concurrency
	if conc <= 0 {
		conc = 10
	}

	logf("")
	logf("====================================================================")
	logf("▶ 阶段1/2：SHA1 指纹比对")
	logf("====================================================================")
	logf("   目标 SHA1: %s | 并发: %d", target, conc)

	file, err := os.Open(*dataFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, "读取 data.txt 失败:", err)
		return nil
	}
	data, err := io.ReadAll(file)
	if err != nil {
		fmt.Fprintln(os.Stderr, "读取 data.txt 失败:", err)
		file.Close()
		return nil
	}
	file.Close()
	jobs, parseErr := selectServices(data)

	totalJobs := len(jobs)
	logf("   待检测目标数量: %d", totalJobs)
	if totalJobs == 0 {
		return nil
	}

	jobChan := make(chan shaJob, 256)
	var wg sync.WaitGroup
	matchedResults := NewSafeResults()
	var processed, matched, failed int64

	transport := &http.Transport{
		MaxIdleConns:        conc,
		MaxIdleConnsPerHost: conc,
		IdleConnTimeout:     30 * time.Second,
	}

	if proxyURL != nil {
		transport.Proxy = http.ProxyURL(proxyURL)
	}
	client := &http.Client{Timeout: shaHTTPTimeout, Transport: transport}

	for i := 0; i < conc; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for job := range jobChan {
				select {
				case <-ctx.Done():
					return
				default:
				}
				var (
					sha1Hash string
					lastErr  error
				)
				for attempt := 0; attempt <= retryAttempts; attempt++ {
					sha1Hash, lastErr = fetchSHA1(ctx, client, job.URL)
					if lastErr == nil {
						break
					}
				}

				cur := atomic.AddInt64(&processed, 1)
				if lastErr != nil {
					atomic.AddInt64(&failed, 1)
				} else if sha1Hash == target {
					atomic.AddInt64(&matched, 1)
					if !*quiet {
						logf("[匹配] %s:%d ✅", job.IP, job.Port)
					}
					matchedResults.Add(&TestResult{IP: job.IP, Port: strconv.Itoa(job.Port)})
				}
				if !*quiet && cur%progressInterval == 0 {
					logf("[进度] 剩余 %d | 匹配 %d | 失败 %d",
						int64(totalJobs)-cur, atomic.LoadInt64(&matched), atomic.LoadInt64(&failed))
				}
			}
		}()
	}

	for _, job := range jobs {
		jobChan <- job
	}
	close(jobChan)
	wg.Wait()

	if parseErr {
		fmt.Fprintln(os.Stderr, "⚠️  解析过程中出现错误，仅处理了已成功解析的部分")
	}
	logf("✅ 阶段1 完成 | 总处理 %d | 匹配 %d | 失败 %d",
		atomic.LoadInt64(&processed), atomic.LoadInt64(&matched), atomic.LoadInt64(&failed))

	return matchedResults.Snapshot()
}

type TestResult struct {
	IP      string
	Port    string
	Latency int64
	Speed   float64

	Reason string
}

type SafeResults struct {
	results []*TestResult
	mu      sync.Mutex
}

func NewSafeResults() *SafeResults { return &SafeResults{} }

func (s *SafeResults) Add(r *TestResult) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.results = append(s.results, r)
}

func (s *SafeResults) Snapshot() []*TestResult {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]*TestResult, len(s.results))
	copy(out, s.results)
	return out
}

type ClientPool struct {
	dialTimeout     time.Duration
	downloadTimeout time.Duration

	mu      sync.Mutex
	clients map[string]*http.Client
	order   []string
}

const maxPooledClients = 128

func (p *ClientPool) remember(target string, client *http.Client) {
	p.clients[target] = client
	p.order = append(p.order, target)
	for len(p.order) > maxPooledClients {
		oldest := p.order[0]
		p.order = p.order[1:]
		if old, ok := p.clients[oldest]; ok {
			old.CloseIdleConnections()
			delete(p.clients, oldest)
		}
	}
}

func NewClientPool(dial, download time.Duration) *ClientPool {
	return &ClientPool{dialTimeout: dial, downloadTimeout: download, clients: make(map[string]*http.Client)}
}

var androidCertDirs = []string{
	"/apex/com.android.conscrypt/cacerts",
	"/system/etc/security/cacerts",
	"/data/misc/keychain/certs-added",
}

var (
	rootCAsOnce sync.Once
	rootCAs     *x509.CertPool
)

func systemRootCAs() *x509.CertPool {
	rootCAsOnce.Do(func() {
		pool, err := x509.SystemCertPool()
		if err != nil || pool == nil {
			pool = x509.NewCertPool()
		}
		added := 0
		probed := make([]string, 0, len(androidCertDirs))
		for _, dir := range androidCertDirs {
			entries, err := os.ReadDir(dir)
			if err != nil {
				continue
			}
			count := 0
			for _, e := range entries {
				if e.IsDir() {
					continue
				}
				pem, err := os.ReadFile(filepath.Join(dir, e.Name()))
				if err != nil {
					continue
				}
				if pool.AppendCertsFromPEM(pem) {
					count++
				}
			}
			if count > 0 {
				added += count
				probed = append(probed, fmt.Sprintf("%s %d", dir, count))
			}
		}
		if added > 0 {
			logf("   TLS 根证书：补载 %d 张（%s）", added, strings.Join(probed, "、"))
		} else {
			logf("   TLS 根证书：系统目录里没读到证书，HTTPS 会以 unknown authority 失败")
		}
		rootCAs = pool
	})
	return rootCAs
}

func (p *ClientPool) NewClient(ip string, port int) *http.Client {
	p.mu.Lock()
	defer p.mu.Unlock()
	target := net.JoinHostPort(ip, strconv.Itoa(port))
	if c, ok := p.clients[target]; ok {
		return c
	}

	dialer := &net.Dialer{Timeout: p.dialTimeout, KeepAlive: 10 * time.Second}

	tlsCfg := &tls.Config{}
	if cfg.Insecure || *insecure {
		tlsCfg.InsecureSkipVerify = true
	} else {

		tlsCfg.RootCAs = systemRootCAs()
	}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {

			if proxyURL != nil {
				return dialTunnelViaProxy(ctx, proxyURL.Host, target, p.dialTimeout)
			}
			return dialer.DialContext(ctx, network, target)
		},
		TLSClientConfig:     tlsCfg,
		ForceAttemptHTTP2:   true,
		MaxIdleConns:        2,
		MaxIdleConnsPerHost: 2,
		IdleConnTimeout:     30 * time.Second,
	}
	client := &http.Client{Transport: transport, Timeout: p.downloadTimeout}
	p.remember(target, client)
	return client
}

func dialTunnelViaProxy(ctx context.Context, proxyAddr, target string, timeout time.Duration) (net.Conn, error) {
	d := &net.Dialer{Timeout: timeout}
	conn, err := d.DialContext(ctx, "tcp", proxyAddr)
	if err != nil {
		return nil, err
	}
	req := fmt.Sprintf("CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Connection: keep-alive\r\n\r\n", target, target)
	if _, err := conn.Write([]byte(req)); err != nil {
		conn.Close()
		return nil, err
	}

	br := bufio.NewReader(conn)
	statusLine, err := br.ReadString('\n')
	if err != nil {
		conn.Close()
		return nil, err
	}
	fields := strings.Fields(statusLine)
	if len(fields) < 2 {
		conn.Close()
		return nil, fmt.Errorf("代理返回异常状态行: %q", strings.TrimSpace(statusLine))
	}
	code, _ := strconv.Atoi(fields[1])
	for {
		line, err := br.ReadString('\n')
		if err != nil {
			conn.Close()
			return nil, err
		}
		if line == "\r\n" || line == "\n" {
			break
		}
	}
	if code != http.StatusOK {
		conn.Close()
		return nil, fmt.Errorf("代理 CONNECT %s 返回 %d", target, code)
	}
	return &bufferedConn{Conn: conn, r: br}, nil
}

type bufferedConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) { return c.r.Read(p) }

func measureTCPLatency(ctx context.Context, ip, port string, timeout time.Duration) int64 {
	target := net.JoinHostPort(ip, port)
	start := time.Now()

	select {
	case <-ctx.Done():
		return -1
	default:
	}

	var (
		conn net.Conn
		err  error
	)
	if proxyURL != nil {
		conn, err = dialTunnelViaProxy(ctx, proxyURL.Host, target, timeout)
	} else {
		d := &net.Dialer{Timeout: timeout}
		conn, err = d.DialContext(ctx, "tcp", target)
	}
	if err != nil {
		return -1
	}
	defer conn.Close()

	if proxyURL != nil {
		_ = conn.SetDeadline(time.Now().Add(timeout))
		if _, err := conn.Write([]byte("GET / HTTP/1.0\r\nHost: " + target + "\r\n\r\n")); err != nil {
			return -1
		}
		if _, err := io.ReadFull(conn, make([]byte, 1)); err != nil {
			return -1
		}
	}

	return time.Since(start).Milliseconds()
}

const (
	stageConnect = "connect"
	stageWarmup  = "warmup"
	stageBody    = "body"
	stageCancel  = "cancel"
)

type speedOutcome struct {
	Speed  float64
	Stage  string
	Err    string
	Status int

	Cancelled bool
}

const speedDisplayEpsilon = 0.005

func measureDownload(ctx context.Context, client *http.Client, speedURL string) speedOutcome {
	select {
	case <-ctx.Done():
		return speedOutcome{Stage: stageCancel, Err: "已取消"}
	default:
	}

	req, err := http.NewRequestWithContext(ctx, "GET", speedURL, nil)
	if err != nil {
		return speedOutcome{Stage: stageConnect, Err: err.Error()}
	}
	req.Header.Set("Accept-Encoding", "identity")
	resp, err := client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return speedOutcome{Stage: stageCancel, Err: "已取消"}
		}

		var uerr *url.Error
		if errors.As(err, &uerr) && uerr.Err != nil {
			err = uerr.Err
		}
		return speedOutcome{Stage: stageConnect, Err: describeIOError(err, ctx)}
	}
	defer resp.Body.Close()

	out := speedOutcome{Status: resp.StatusCode}
	warmed, warmErr := io.CopyN(io.Discard, resp.Body, speedWarmupBytes)
	windowStart := time.Now()
	windowTimer := time.AfterFunc(
		time.Duration(speedWindowSeconds*float64(time.Second)),
		func() { _ = resp.Body.Close() },
	)
	written, _ := io.CopyN(io.Discard, resp.Body, speedWindowMaxBytes)
	windowTimer.Stop()
	elapsed := time.Since(windowStart).Seconds()

	cancelled := ctx.Err() != nil
	if warmErr != nil && elapsed == 0 && warmed < speedWarmupBytes {
		if warmed > 0 {
			out.Speed = float64(warmed) / speedWindowSeconds / (1024 * 1024)
			out.Cancelled = cancelled
			return out
		}
		if cancelled {
			return speedOutcome{Stage: stageCancel, Err: "已取消"}
		}
		out.Stage = stageWarmup
		out.Err = describeIOError(warmErr, ctx)
		return out
	}
	if elapsed == 0 {
		out.Stage = stageBody
		out.Err = "计量窗口为 0"
		return out
	}
	if written == 0 {
		if cancelled {
			return speedOutcome{Stage: stageCancel, Err: "已取消"}
		}
		out.Speed = 0
		out.Stage = stageBody
		out.Err = fmt.Sprintf("响应体为空（HTTP %d）", resp.StatusCode)
		return out
	}
	denominator := elapsed
	if denominator < speedMinWindowSeconds {
		denominator = speedMinWindowSeconds
	}
	out.Speed = float64(written) / denominator / (1024 * 1024)
	out.Cancelled = cancelled
	return out
}

const (
	speedWindowSeconds    = 3.0
	speedWindowMaxBytes   = 64 * 1024 * 1024
	speedWarmupBytes      = 256 * 1024
	speedMinWindowSeconds = 1.0
)

func describeIOError(err error, ctx context.Context) string {
	if err == nil {
		return ""
	}

	if errors.Is(ctx.Err(), context.Canceled) {
		return "已取消"
	}
	if errors.Is(err, io.EOF) {
		return "EOF（对端未返回任何数据）"
	}
	var opErr *net.OpError
	if errors.As(err, &opErr) && opErr.Addr != nil && opErr.Err != nil {
		op := opErr.Op
		if op == "" {
			op = "io"
		}
		err = fmt.Errorf("%s->%s: %v", op, opErr.Addr, opErr.Err)
	}
	msg := strings.ReplaceAll(err.Error(), "\n", " ")
	msg = strings.ReplaceAll(msg, "\r", " ")
	if len(msg) > 160 {
		msg = msg[:160]
	}
	return msg
}

func logSpeedLine(cur, total int, ip, port string, out speedOutcome) {
	if *quiet {
		return
	}
	if out.Cancelled {
		logf("[速度 %d/%d] %s:%s 失败 stage=%s err=%s", cur, total, ip, port, stageCancel,
			fmt.Sprintf("已取消（读数偏低估，约 %.2f MiB/s 仅供参考）", out.Speed))
		return
	}
	if out.Speed >= speedDisplayEpsilon {
		logf("[速度 %d/%d] %s:%s %.2f MiB/s", cur, total, ip, port, out.Speed)
		return
	}
	if out.Stage == "" {

		logf("[速度 %d/%d] %s:%s 失败 stage=%s err=速率为 0（实测 %.4f MiB/s）",
			cur, total, ip, port, stageBody, out.Speed)
		return
	}
	logf("[速度 %d/%d] %s:%s 失败 stage=%s err=%s", cur, total, ip, port, out.Stage, out.Err)
}

func writeResultCSV(sorted []*TestResult) error {
	resultFile, err := os.Create(*resultCSV)
	if err != nil {
		return fmt.Errorf("创建结果文件失败: %w", err)
	}
	defer resultFile.Close()

	writer := csv.NewWriter(resultFile)
	defer writer.Flush()

	rows := make([][]string, 0, len(sorted)+1)
	rows = append(rows, []string{"IP", "Port", "Latency (ms)", "Speed (MiB/s)", "Reason"})
	for _, r := range sorted {
		rows = append(rows, []string{
			r.IP, r.Port,
			fmt.Sprintf("%d", r.Latency),
			fmt.Sprintf("%.2f", r.Speed),
			r.Reason,
		})
	}
	if err := writer.WriteAll(rows); err != nil {
		return fmt.Errorf("CSV 写入失败: %w", err)
	}
	writer.Flush()
	if err := writer.Error(); err != nil {
		return fmt.Errorf("CSV flush 失败: %w", err)
	}
	return nil
}

func speedStats(results []*TestResult) (ok, zero, fail int) {
	for _, r := range results {
		switch {
		case r.Reason == reasonZeroRate:
			zero++
		case r.Reason != "":
			fail++
		default:
			ok++
		}
	}
	return ok, zero, fail
}

// runLatencyStage 对 ipsToTest 做一轮 TCP 延迟测量。
//
// 原地写入每个目标的 Latency；连接失败的条目同时写入 Reason（这样
// 「只延迟」模式可以直接把它们写进 CSV）。
//
// [applyThreshold] 决定是否把超过 cfg.MaxLatency 的条目判为失败：
//   - 速度/一键模式传 true：阈值用于「筛掉高延迟候选」，让速度阶段少测几条；
//   - 只延迟模式传 false：用户点「延迟测试」是想看每条候选的真实延迟，
//     200ms 的默认阈值会把大量跨境候选直接标成失败，看起来像「全挂了」。
func runLatencyStage(
	ctx context.Context, ipsToTest []*TestResult, applyThreshold bool,
) []*TestResult {
	if len(ipsToTest) == 0 {
		fmt.Fprintln(os.Stderr, "没有找到待测试的 IP")
		return nil
	}

	dialTimeout := time.Duration(cfg.DialTimeout) * time.Second

	logf("")
	logf("   ----- 延迟测试 -----")
	passed := NewSafeResults()
	totalIPs := int32(len(ipsToTest))
	var latencyDone int32
	var latencyWg sync.WaitGroup
	latencySem := make(chan struct{}, cfg.MaxLatencyConcurrency)

	for _, result := range ipsToTest {
		latencyWg.Add(1)
		latencySem <- struct{}{}
		go func(result *TestResult) {
			defer latencyWg.Done()
			defer func() { <-latencySem }()

			select {
			case <-ctx.Done():
				result.Latency = -1
				result.Reason = reasonCancelled
				return
			default:
			}

			latency := measureTCPLatency(ctx, result.IP, result.Port, dialTimeout)
			result.Latency = latency
			cur := atomic.AddInt32(&latencyDone, 1)

			switch {
			case latency < 0:
				result.Reason = "延迟测试失败"
				if !*quiet {
					logf("   [延迟 %d/%d] %s:%s 连接失败", cur, totalIPs, result.IP, result.Port)
				}
			case applyThreshold && cfg.MaxLatency > 0 && latency > cfg.MaxLatency:
				result.Reason = fmt.Sprintf("延迟 %dms 超过阈值 %dms", latency, cfg.MaxLatency)
				if !*quiet {
					logf("   [延迟 %d/%d] %s:%s %dms (超过阈值)", cur, totalIPs, result.IP, result.Port, latency)
				}
			default:
				if !*quiet {
					logf("   [延迟 %d/%d] %s:%s %dms", cur, totalIPs, result.IP, result.Port, latency)
				}
				passed.Add(result)
			}
		}(result)
	}
	latencyWg.Wait()

	passedList := passed.Snapshot()
	if len(passedList) == 0 {
		fmt.Fprintln(os.Stderr, "没有 IP 通过延迟测试")
		return nil
	}
	if !applyThreshold {
		logf("   延迟测试完成，%d/%d 个 IP 可连通（只延迟模式不按阈值筛选）",
			len(passedList), len(ipsToTest))
	} else if cfg.MaxLatency > 0 {
		logf("   延迟测试完成，%d/%d 个 IP 通过（阈值 %dms）", len(passedList), len(ipsToTest), cfg.MaxLatency)
	} else {
		logf("   延迟测试完成，%d/%d 个 IP 通过（未设阈值，只保留能连通的）", len(passedList), len(ipsToTest))
	}
	return passedList
}

func runSpeedTest(ctx context.Context, ipsToTest []*TestResult) []*TestResult {
	logf("")
	logf("====================================================================")
	logf("▶ 阶段2/2：延迟 + 速度测试")
	logf("====================================================================")

	if len(ipsToTest) == 0 {
		fmt.Fprintln(os.Stderr, "没有找到待测试的 IP")
		return nil
	}

	logf("   共加载 %d 个 IP", len(ipsToTest))

	passedList := runLatencyStage(ctx, ipsToTest, true)
	if passedList == nil {
		// 一条都没通过延迟测试：与「只延迟」模式对齐，把失败明细落盘，
		// 让 Dart 侧在 code != 0 时仍能读到部分结果；返回值仍是 nil → 调用方 exit 1。
		writeLatencyFailureCSV(ipsToTest)
		return nil
	}

	logf("")
	logf("   ----- 速度测试 -----")
	dialTimeout := time.Duration(cfg.DialTimeout) * time.Second
	downloadTimeout := time.Duration(cfg.DownloadTimeout) * time.Second
	clientPool := NewClientPool(dialTimeout, downloadTimeout)

	sorted := runSpeedStage(ctx, passedList, clientPool)
	if sorted == nil {
		return nil
	}
	return sorted
}

func runSpeedStage(ctx context.Context, candidates []*TestResult, clientPool *ClientPool) []*TestResult {
	workers := cfg.MaxSpeedConcurrency
	if workers < 1 {
		workers = 1
	}
	logSpeedWindowPlan(workers)

	total := int32(len(candidates))
	all := NewSafeResults()
	var logMu sync.Mutex
	done := 0
	queued := 0

	record := func(r *TestResult, out speedOutcome) {
		logMu.Lock()
		done++
		cur := done
		logSpeedLine(cur, int(total), r.IP, r.Port, out)
		logMu.Unlock()
		all.Add(r)
	}

	jobs := make(chan *TestResult)
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for r := range jobs {
				port, _ := strconv.Atoi(r.Port)
				client := clientPool.NewClient(r.IP, port)
				out := measureDownload(ctx, client, cfg.SpeedTestURL)

				r.Speed = out.Speed
				r.Reason = speedReason(out)

				record(r, out)
			}
		}()
	}

	for _, result := range candidates {
		select {
		case jobs <- result:
			logMu.Lock()
			queued++
			logMu.Unlock()
		case <-ctx.Done():
			break
		}
		if ctx.Err() != nil {
			break
		}
	}
	close(jobs)
	wg.Wait()

	if ctx.Err() != nil {
		for _, result := range candidates[queued:] {
			result.Speed = 0
			result.Reason = reasonCancelled
			all.Add(result)
		}
	}

	sorted := all.Snapshot()

	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Speed > sorted[j].Speed })

	if !reportSpeedResults(sorted) {
		return nil
	}
	return sorted
}

const (
	reasonZeroRate = "速率为 0"

	reasonCancelledTruncated = "已取消（读数偏低估）"

	reasonCancelled = "已取消"
)

func speedReason(out speedOutcome) string {

	if out.Cancelled {
		return reasonCancelledTruncated
	}
	if out.Speed >= speedDisplayEpsilon {
		return ""
	}
	if out.Stage == "" {
		return reasonZeroRate
	}
	if out.Stage == stageCancel {
		return reasonCancelled
	}
	return fmt.Sprintf("%s: %s", out.Stage, out.Err)
}

func readSpeedTargets(path string) ([]*TestResult, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("读取 targets 清单失败: %w", err)
	}
	defer file.Close()

	var out []*TestResult
	scanner := bufio.NewScanner(file)
	lineno := 0
	for scanner.Scan() {
		lineno++
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Split(line, ",")
		endpoint := strings.TrimSpace(fields[0])
		latency := int64(-1)
		if len(fields) > 1 {
			if v := strings.TrimSpace(fields[1]); v != "" {
				parsed, perr := strconv.ParseInt(v, 10, 64)
				if perr != nil {
					return nil, fmt.Errorf("第 %d 行延迟字段不是整数: %q", lineno, v)
				}
				latency = parsed
			}
		}
		ip, port, perr := splitEndpoint(endpoint)
		if perr != nil {
			return nil, fmt.Errorf("第 %d 行%v", lineno, perr)
		}
		out = append(out, &TestResult{IP: ip, Port: port, Latency: latency})
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("读取 targets 清单失败: %w", err)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("targets 清单里没有有效条目: %s", path)
	}
	return out, nil
}

func splitEndpoint(endpoint string) (ip, port string, err error) {
	idx := strings.LastIndex(endpoint, ":")
	if idx <= 0 || idx == len(endpoint)-1 {
		return "", "", fmt.Errorf("目标格式应为 ip:port，实际 %q", endpoint)
	}
	ip = endpoint[:idx]
	port = endpoint[idx+1:]
	if strings.HasPrefix(ip, "[") && strings.HasSuffix(ip, "]") {
		ip = ip[1 : len(ip)-1]
	}
	n, cerr := strconv.Atoi(port)
	if cerr != nil {
		return "", "", fmt.Errorf("端口不是整数: %q", port)
	}
	if n < 1 || n > 65535 {
		return "", "", fmt.Errorf("端口越界（1~65535）: %d", n)
	}
	return ip, port, nil
}

func logSpeedPlan(total int) {
	logf("")
	logf("====================================================================")
	logf("▶ 阶段3/3：速度测试（只测速模式）")
	logf("====================================================================")
	logf("   候选数量: %d | 并发: %d | 单 IP 超时: %ds", total, cfg.MaxSpeedConcurrency, cfg.DownloadTimeout)
	logf("   测速地址: %s", cfg.SpeedTestURL)
}

func logSpeedWindowPlan(workers int) {
	if *quiet {
		return
	}
	logf("   单次下载: 并发 %d | 首 %d KiB 预热 | 计量窗口 %.0fs（上限 %d MiB）",
		workers, speedWarmupBytes/1024, speedWindowSeconds, speedWindowMaxBytes/(1024*1024))
}

// reportSpeedResults 打印汇总并写 result.csv。
//
// 退出码口径与 reportLatencyResults 完全一致：**只看有没有可用结果**。
// 「可用」直接复用 speedStats 的 ok 计数（Reason 为空，即实测速率
// >= speedDisplayEpsilon）；零速率与各类失败都不算可用。
//
// 返回 true 仅在「有结果、已写盘、且 ok > 0」时成立。全部失败 / 全部零速率
// 属于「一次都没有可用结果」，返回 false，由调用方转成 exit 1
// （`-only-speed` 与 `-targets` 全量模式共用这一处判定）。
// 注意：即使一条都没成功，CSV 也照旧写盘，Dart 侧在 code != 0 时能读到明细。
func reportSpeedResults(sorted []*TestResult) bool {
	ok, zero, fail := speedStats(sorted)
	logf("[汇总] 总数=%d 成功=%d 零速率=%d 失败=%d", len(sorted), ok, zero, fail)

	if len(sorted) == 0 {
		fmt.Fprintln(os.Stderr, "没有测速结果")
		return false
	}
	if err := writeResultCSV(sorted); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return false
	}
	logf("   测试完成，共 %d 个 IP，结果已写入 %s", len(sorted), *resultCSV)
	if ok == 0 {
		fmt.Fprintln(os.Stderr, "❌ 没有任何 IP 测出可用速率，视为无可用结果")
		return false
	}
	return true
}

func runProtocolSelftest() {
	cfg.MaxSpeedConcurrency = 2
	cfg.DownloadTimeout = 5
	cfg.SpeedTestURL = "https://speed.cloudflare.com/__down?bytes=209715200"

	cases := []struct {
		ip   string
		port string
		out  speedOutcome
	}{
		{"203.0.113.10", "443", speedOutcome{Speed: 858.23, Status: 200}},
		{"203.0.113.11", "8443", speedOutcome{Speed: 811.69, Status: 200}},
		{"203.0.113.12", "2053", speedOutcome{Speed: 0.0001}},
		{"203.0.113.13", "2087", speedOutcome{Stage: stageWarmup, Err: "EOF（对端未返回任何数据）"}},
		{"203.0.113.14", "80", speedOutcome{Stage: stageConnect, Err: "dial->203.0.113.14:80: connect: connection refused"}},
		{"203.0.113.15", "8080", speedOutcome{Stage: stageCancel, Speed: 0.48, Cancelled: true}},
	}

	logSpeedPlan(len(cases))
	logSpeedWindowPlan(cfg.MaxSpeedConcurrency)

	results := make([]*TestResult, 0, len(cases))
	for i, c := range cases {
		r := &TestResult{IP: c.ip, Port: c.port, Latency: 42, Speed: c.out.Speed}
		r.Reason = speedReason(c.out)
		logSpeedLine(i+1, len(cases), r.IP, r.Port, c.out)
		results = append(results, r)
	}

	sort.SliceStable(results, func(i, j int) bool { return results[i].Speed > results[j].Speed })
	reportSpeedResults(results)
}

func runListOnly() int {
	file, err := os.Open(*dataFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, "读取 data.txt 失败:", err)
		return 1
	}
	data, err := io.ReadAll(file)
	if err != nil {
		fmt.Fprintln(os.Stderr, "读取 data.txt 失败:", err)
		file.Close()
		return 1
	}
	file.Close()
	jobs, broken := selectServices(data)
	for _, job := range jobs {
		logf("%s:%d", job.IP, job.Port)
	}
	if broken {
		fmt.Fprintln(os.Stderr, "⚠️  解析过程中出现错误，仅列出已成功解析的部分")
		return 1
	}
	return 0
}

// writeLatencyFailureCSV 把「没有任何目标通过延迟测试」的明细写进 result.csv。
//
// 与「只延迟」模式（runLatencyOnly → reportLatencyResults）对齐：即便一条都没
// 通过也照旧落盘，Dart 侧才能在 code != 0 时读到部分结果并展示失败原因。
// 写盘失败只打日志，不影响退出码——该场景恒为 exit 1。
func writeLatencyFailureCSV(targets []*TestResult) {
	if len(targets) == 0 {
		return
	}
	if err := writeResultCSV(targets); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return
	}
	logf("   失败明细已写入 %s（共 %d 条，均未通过延迟测试）", *resultCSV, len(targets))
}

// runSpeedOnly 只跑速度阶段（-only-speed）：不做延迟筛选，
// Latency 沿用清单里的值（没给就是 -1）。
//
// 返回 nil 表示「没有可用结果」：全部失败、全部零速率、或写 CSV 失败。
// 判定在 reportSpeedResults 里完成，与 -only-latency / -targets 三种模式
// 口径统一——**一次都没有可用结果 → exit 1**；失败明细照旧写进 result.csv。
func runSpeedOnly(ctx context.Context, targets []*TestResult) []*TestResult {
	dialTimeout := time.Duration(cfg.DialTimeout) * time.Second
	downloadTimeout := time.Duration(cfg.DownloadTimeout) * time.Second

	logSpeedPlan(len(targets))

	return runSpeedStage(ctx, targets, NewClientPool(dialTimeout, downloadTimeout))
}

func logLatencyPlan(total int) {
	logf("")
	logf("====================================================================")
	logf("▶ 阶段2/2：延迟测试（只延迟模式）")
	logf("====================================================================")
	logf("   候选数量: %d | 并发: %d | 单 IP 超时: %ds", total, cfg.MaxLatencyConcurrency, cfg.DialTimeout)
	if cfg.MaxLatency > 0 {
		logf("   延迟阈值: %dms（超过记为失败）", cfg.MaxLatency)
	} else {
		logf("   延迟阈值: 未设置（只要求能连通）")
	}
}

// runLatencyOnly 只跑延迟阶段，并把**全部**目标（含失败）写进 result.csv。
//
// 与只测速模式对齐：Speed 记 0，失败原因写进 Reason。
// 返回值 ok 表示「至少 1 条通过延迟测试且结果已落盘」；为 false 时调用方
// 应 os.Exit(1)，与 -only-speed 的「没有可用结果」口径保持一致。
// 即使全部失败，失败明细也照旧写进 result.csv，便于排查。
func runLatencyOnly(
	ctx context.Context, targets []*TestResult,
) (results []*TestResult, ok bool) {
	logLatencyPlan(len(targets))

	// 忽略返回值：失败项也要进 CSV，所以直接复用被原地写好的 targets。
	_ = runLatencyStage(ctx, targets, false)

	sorted := make([]*TestResult, len(targets))
	copy(sorted, targets)
	sort.SliceStable(sorted, func(i, j int) bool {
		a, b := sorted[i].Latency, sorted[j].Latency
		// 失败项（延迟为负）永远排最后。
		if (a < 0) != (b < 0) {
			return b < 0
		}
		if a < 0 {
			return false
		}
		return a < b
	})

	return sorted, reportLatencyResults(sorted)
}

// reportLatencyResults 打印汇总并写 result.csv。
//
// 返回 true 仅在「有结果、已写盘、且至少 1 条通过延迟测试」时成立；
// 全部失败属于「无可用结果」，返回 false 由调用方转成 exit 1。
func reportLatencyResults(sorted []*TestResult) bool {
	ok := 0
	for _, r := range sorted {
		if r.Reason == "" {
			ok++
		}
	}
	logf("[汇总] 总数=%d 成功=%d 失败=%d", len(sorted), ok, len(sorted)-ok)

	if len(sorted) == 0 {
		fmt.Fprintln(os.Stderr, "没有延迟测试结果")
		return false
	}
	if err := writeResultCSV(sorted); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return false
	}
	logf("   延迟测试完成，共 %d 个 IP，结果已写入 %s", len(sorted), *resultCSV)
	if ok == 0 {
		fmt.Fprintln(os.Stderr, "❌ 没有任何 IP 通过延迟测试，视为无可用结果")
		return false
	}
	return true
}

func main() {
	flag.Parse()

	if *selftest {
		runProtocolSelftest()
		return
	}

	if *listOnly {
		os.Exit(runListOnly())
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	cfgData, err := os.ReadFile(*configFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "读取配置 %s 失败: %v\n", *configFile, err)
		os.Exit(1)
	}
	if err := json.Unmarshal(cfgData, &cfg); err != nil {
		fmt.Fprintf(os.Stderr, "解析配置 %s 失败: %v\n", *configFile, err)
		os.Exit(1)
	}

	if *proxyFlag != "" {
		cfg.HTTPProxy = *proxyFlag
	}
	if cfg.MaxSha1Concurrency <= 0 {
		cfg.MaxSha1Concurrency = 10
	}
	if cfg.DialTimeout <= 0 {
		cfg.DialTimeout = 5
	}
	if cfg.DownloadTimeout <= 0 {
		cfg.DownloadTimeout = 15
	}
	if cfg.MaxLatencyConcurrency <= 0 {
		cfg.MaxLatencyConcurrency = 100
	}
	if cfg.MaxSpeedConcurrency <= 0 {
		cfg.MaxSpeedConcurrency = 5
	}

	if cfg.HTTPProxy != "" {
		if pu, perr := url.Parse(cfg.HTTPProxy); perr == nil && pu.Host != "" {
			proxyURL = pu
		} else {
			fmt.Fprintln(os.Stderr, "httpProxy 解析失败，将直连")
		}
	}

	logf("====================================================================")
	logf("▶ Censys 代理筛选流水线（单文件版）")
	logf("====================================================================")
	if proxyURL != nil {
		logf("   代理: %s", proxyURL.String())
	} else {
		logf("   代理: 未配置（直连）")
	}
	if cfg.Insecure || *insecure {
		logf("   ⚠️ TLS 证书校验已关闭（--insecure / config.insecure=true）")
	}

	if *onlySpeed {
		if *targetsFile == "" {
			fmt.Fprintln(os.Stderr, "-only-speed 需要配合 -targets <文件> 使用")
			os.Exit(2)
		}
		targets, terr := readSpeedTargets(*targetsFile)
		if terr != nil {
			fmt.Fprintln(os.Stderr, terr)
			os.Exit(2)
		}
		if len(targets) == 0 {
			fmt.Fprintln(os.Stderr, "没有待测速的候选")
			os.Exit(2)
		}
		// runSpeedOnly 返回 nil = 「一次都没有可用结果」（含全部失败/全部零速率）
		// → exit 1，不是 exit 0。失败明细已由 reportSpeedResults 写进 result.csv，
		// Dart 侧在 code != 0 时照常能读到。
		if runSpeedOnly(ctx, targets) == nil {
			os.Exit(1)
		}
		return
	}

	// 只延迟：延迟阶段复用 runLatencyStage，失败项也写进 CSV（Speed=0）。
	if *onlyLatency {
		if *targetsFile == "" {
			fmt.Fprintln(os.Stderr, "-only-latency 需要配合 -targets <文件> 使用")
			os.Exit(2)
		}
		targets, terr := readSpeedTargets(*targetsFile)
		if terr != nil {
			fmt.Fprintln(os.Stderr, terr)
			os.Exit(2)
		}
		if len(targets) == 0 {
			fmt.Fprintln(os.Stderr, "没有待测延迟的候选")
			os.Exit(2)
		}
		// 全部失败（一条都没通过延迟测试）时 exit 1，与 -only-speed 的
		// 「无可用结果」口径统一；失败明细仍会写进 result.csv 便于排查。
		if _, ok := runLatencyOnly(ctx, targets); !ok {
			os.Exit(1)
		}
		return
	}

	// 带 -targets 且没有 -only-*：延迟 + 速度（跳过指纹筛选阶段）。
	if *targetsFile != "" {
		targets, terr := readSpeedTargets(*targetsFile)
		if terr != nil {
			fmt.Fprintln(os.Stderr, terr)
			os.Exit(2)
		}
		if len(targets) == 0 {
			fmt.Fprintln(os.Stderr, "没有待测试的候选")
			os.Exit(2)
		}
		// 延迟 + 速度：runSpeedTest 返回 nil 同样是「没有可用结果」——
		// 延迟阶段全失败（此时失败明细已落盘）或速度阶段全失败，统一 exit 1。
		sorted := runSpeedTest(ctx, targets)
		if sorted == nil {
			os.Exit(1)
		}
		logf("")
		logf("✅ 全部完成 | 最终产物: %s", *resultCSV)
		return
	}

	matched := runSHA1Filter(ctx)
	if len(matched) == 0 {
		fmt.Fprintln(os.Stderr, "❌ 阶段1 没有命中任何目标，流程中止。")
		os.Exit(1)
	}

	if *onlyIP {
		logf("")
		logf("✅ 已按要求在阶段1 后停止，命中 %d 个（未测速）：", len(matched))
		for _, m := range matched {
			logf("   %s:%s", m.IP, m.Port)
		}
		return
	}

	sorted := runSpeedTest(ctx, matched)
	if sorted == nil {
		os.Exit(1)
	}

	logf("")
	logf("====================================================================")
	logf("▶ 汇总（Top %d / 共 %d 条）", *topN, len(sorted))
	logf("====================================================================")
	logf("   %-18s%-8s%-12s%s", "IP", "端口", "延迟(ms)", "速度(MiB/s)")
	logf("   %s", strings.Repeat("-", 52))
	n := *topN
	if n < 0 {
		n = 0
	}
	if n > len(sorted) {
		n = len(sorted)
	}
	for _, r := range sorted[:n] {
		logf("   %-18s%-8s%-12d%.2f", r.IP, r.Port, r.Latency, r.Speed)
	}
	logf("")
	logf("✅ 全部完成 | 最终产物: %s", *resultCSV)
}
