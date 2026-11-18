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
	sha1Filter  = flag.Bool("sha1", false, "对 -targets 清单先做阶段1 SHA1 指纹比对（与原版同口径：明文 HTTP、读 50MiB、不按端口预筛）")

	// 带 -targets 且没有 -only-* 时：跑「延迟 + 速度」。
	// 与 -only-speed 的区别是：会先做一轮延迟筛选，只给能连通的 IP 测速。
	topN     = flag.Int("top", 10, "汇总时打印前 N 名")
	quiet    = flag.Bool("quiet", false, "不打印逐条匹配/进度明细")
	selftest = flag.Bool("protocol-selftest", false, "打印各分支的协议样例到 stdout 后退出（供契约测试使用；自检模式不产出 result.csv）")
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
	// rootCAState 记录根证书装配结果，供 -protocol-selftest 打印。
	// Android 上这条分支（系统池空 → 靠 cert 目录补载）没有真机就验不了，
	// 所以留一个一行自检出口：真机跑 -protocol-selftest 就能看到走了哪条分支。
	rootCAState certPoolState
)

// certPoolState 是根证书装配结果。判定分支抽成纯函数，
// 日志与自检共用同一套口径，避免两处判断漂移。
type certPoolState struct {
	systemBroken bool // 系统证书库报错或一张证书都没有
	added        int  // 从 Android 证书目录补载的证书数量
	sawCertDir   bool // 是否真的找到了 Android 证书目录
}

// certPoolBranch 是装配结果对应的分支（决定要不要告警）。
type certPoolBranch int

const (
	certBranchLoaded   certPoolBranch = iota // 从证书目录补载成功
	certBranchBroken                         // 系统证书库不可用
	certBranchEmptyDir                       // Android 目录在，但没读到证书
	certBranchDesktop                        // 桌面端：系统库可用，静默
)

func (b certPoolBranch) String() string {
	switch b {
	case certBranchLoaded:
		return "补载成功"
	case certBranchBroken:
		return "系统池不可用"
	case certBranchEmptyDir:
		return "证书目录空"
	default:
		return "桌面端静默"
	}
}

func (s certPoolState) branch() certPoolBranch {
	switch {
	case s.added > 0:
		return certBranchLoaded
	case s.systemBroken:
		return certBranchBroken
	case s.sawCertDir:
		return certBranchEmptyDir
	default:
		return certBranchDesktop
	}
}

// describe 供自检输出：一句话看清平台与分支。
func (s certPoolState) describe() string {
	system := "可用"
	if s.systemBroken {
		system = "空或报错"
	}
	hasDir := "否"
	if s.sawCertDir {
		hasDir = "是"
	}
	return fmt.Sprintf("系统池=%s | 补载=%d 张 | 有证书目录=%s | 分支=%s",
		system, s.added, hasDir, s.branch())
}

func systemRootCAs() *x509.CertPool {
	rootCAsOnce.Do(func() {
		pool, err := x509.SystemCertPool()
		if err != nil || pool == nil {
			pool = x509.NewCertPool()
		}
		// 「系统池可用」不能只看 err/nil：Android 上 SystemCertPool 常常
		// 返回一个**空池**（err 为 nil），真正的证书要靠下面的目录补载。
		// 用 Equal(空池) 判断是否一张证书都没有 —— Subjects() 已废弃，
		// 这里只需判空，而这段是 sync.Once 内的一次性开销，O(n) 没关系。
		state := certPoolState{systemBroken: err != nil || pool.Equal(x509.NewCertPool())}
		probed := make([]string, 0, len(androidCertDirs))
		for _, dir := range androidCertDirs {
			entries, err := os.ReadDir(dir)
			if err != nil {
				continue
			}
			// 目录存在 ≠ 桌面端：这些路径只在 Android 上有。桌面端读不到是正常分支，
			// 以前把「读不到 Android 目录」当成「没有根证书」报警，Windows 上每轮都
			// 打一行误导性警告（HTTPS 其实好好的）。
			state.sawCertDir = true
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
				state.added += count
				probed = append(probed, fmt.Sprintf("%s %d", dir, count))
			}
		}
		rootCAState = state
		switch state.branch() {
		case certBranchLoaded:
			logf("   TLS 根证书：从系统证书目录补载 %d 张（%s）", state.added, strings.Join(probed, "、"))
		case certBranchBroken:
			// 只有「系统证书库本身不可用」才是真的要提醒（Android 上 SystemCertPool
			// 常返回空池，必须靠上面的目录补载）。
			logf("   ⚠️ TLS 根证书：系统证书库不可用或不含证书，HTTPS 会以 unknown authority 失败")
		case certBranchEmptyDir:
			// 走到这里必然 !systemBroken（顺序在 certBranchBroken 之后），
			// 也就是系统 CA 齐全、公共站点 HTTPS 正常 —— 所以**不能**报警，
			// 否则又是「桌面端假警报」的翻版（QA 实测：同状态下
			// 104.16.1.1:443 1599ms 成功）。这里只说明「没补到证书」这一事实，
			// 并点明影响面仅限自建/用户级 CA。
			logf("   TLS 根证书：证书目录存在但未补载到证书（系统 CA 已可用，仅影响自建/用户级 CA）")
		case certBranchDesktop:
			// 桌面端常见路径：系统证书库可用、没有 Android 证书目录 —— 静默。
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

const (
	proxyOpDial    = "dial"
	proxyOpConnect = "connect"
)

// proxyDialError 是「经代理拨号」失败的专用错误类型。
//
// 配了测速代理却连不上时，所有目标会对出一堆 `dial: i/o timeout`，
// 用户完全看不出是代理的锅（只会以为「所有节点都挂了」）。把代理侧的失败
// 单独包一层，就能在 Reason 列直接写「测速代理不可用（127.0.0.1:10809）：连接被拒绝」。
type proxyDialError struct {
	Proxy  string
	Target string
	Op     string
	Err    error
}

func (e *proxyDialError) Error() string {
	if e.Op == proxyOpDial {
		return fmt.Sprintf("测速代理不可用（%s）：%s", e.Proxy, describeProxyReason(e.Err))
	}
	return fmt.Sprintf("代理隧道失败（%s → %s）：%s",
		e.Proxy, e.Target, describeIOError(e.Err, context.Background()))
}

func (e *proxyDialError) Unwrap() error { return e.Err }

// Windows 上 syscall.ECONNREFUSED 是 application-error 常量（536870934），
// 而 ConnectEx/WSARecv 真正返回的是 Winsock errno（10061 等），
// errors.Is(err, syscall.ECONNREFUSED) 在 Windows 上恒为 false —— 这会让
// 「连接被拒绝」被摊成一句 raw 英文。所以按下表再比一次数值。
const (
	wsaNetUnreach  = 10051 // WSAENETUNREACH
	wsaConnReset   = 10054 // WSAECONNRESET
	wsaTimedOut    = 10060 // WSAETIMEDOUT
	wsaConnRefused = 10061 // WSAECONNREFUSED
	wsaHostUnreach = 10065 // WSAEHOSTUNREACH
)

// errnoOf 取出错误链里的 syscall.Errno（*os.SyscallError 的叶子就是它）。
func errnoOf(err error) (syscall.Errno, bool) {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		return errno, true
	}
	return 0, false
}

func hasErrno(err error, codes ...syscall.Errno) bool {
	got, ok := errnoOf(err)
	if !ok {
		return false
	}
	for _, c := range codes {
		if got == c {
			return true
		}
	}
	return false
}

// isConnRefused 连接被拒绝（端口没开）。
func isConnRefused(err error) bool {
	return errors.Is(err, syscall.ECONNREFUSED) || hasErrno(err, syscall.Errno(wsaConnRefused))
}

// isConnReset 连接被对端重置。
func isConnReset(err error) bool {
	return errors.Is(err, syscall.ECONNRESET) || hasErrno(err, syscall.Errno(wsaConnReset))
}

// isUnreachable 主机/网络不可达。
func isUnreachable(err error) bool {
	return errors.Is(err, syscall.EHOSTUNREACH) || errors.Is(err, syscall.ENETUNREACH) ||
		hasErrno(err, syscall.Errno(wsaHostUnreach), syscall.Errno(wsaNetUnreach))
}

// isTimeoutErr 含 Winsock 的 WSAETIMEDOUT：该 errno 不实现 net.Error.Timeout()。
func isTimeoutErr(err error) bool {
	var nerr net.Error
	if errors.As(err, &nerr) && nerr.Timeout() {
		return true
	}
	return hasErrno(err, syscall.Errno(wsaTimedOut))
}

// describeProxyReason 把「连代理本身」失败的原因翻成人话。
func describeProxyReason(err error) string {
	if err == nil {
		return "未知原因"
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return fmt.Sprintf("代理地址解析失败（%s）", dnsErr.Name)
	}
	if isTimeoutErr(err) {
		return "连接超时（代理没响应）"
	}
	switch {
	case isConnRefused(err):
		return "连接被拒绝（代理没在运行？）"
	case isConnReset(err):
		return "连接被重置"
	case isUnreachable(err):
		return "网络不可达"
	}
	return describeIOError(err, context.Background())
}

func dialTunnelViaProxy(ctx context.Context, proxyAddr, target string, timeout time.Duration) (net.Conn, error) {
	d := &net.Dialer{Timeout: timeout}
	conn, err := d.DialContext(ctx, "tcp", proxyAddr)
	if err != nil {
		return nil, &proxyDialError{Proxy: proxyAddr, Target: target, Op: proxyOpDial, Err: err}
	}
	fail := func(err error) (net.Conn, error) {
		conn.Close()
		return nil, &proxyDialError{Proxy: proxyAddr, Target: target, Op: proxyOpConnect, Err: err}
	}

	req := fmt.Sprintf("CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Connection: keep-alive\r\n\r\n", target, target)
	if _, err := conn.Write([]byte(req)); err != nil {
		return fail(err)
	}

	br := bufio.NewReader(conn)
	statusLine, err := br.ReadString('\n')
	if err != nil {
		return fail(err)
	}
	fields := strings.Fields(statusLine)
	if len(fields) < 2 {
		return fail(fmt.Errorf("代理返回异常状态行: %q", strings.TrimSpace(statusLine)))
	}
	code, _ := strconv.Atoi(fields[1])
	for {
		line, err := br.ReadString('\n')
		if err != nil {
			return fail(err)
		}
		if line == "\r\n" || line == "\n" {
			break
		}
	}
	if code != http.StatusOK {
		return fail(fmt.Errorf("CONNECT %s 返回 %d", target, code))
	}
	return &bufferedConn{Conn: conn, r: br}, nil
}

type bufferedConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) { return c.r.Read(p) }

// latencyOutcome 是一次延迟探测的结果。
//
// 口径 = 原版 `measureTCPLatency`（censys-speedtest 的 src/pipeline.go:401）：
// **只测 TCP 握手**。直连时就是 `DialContext` 的往返；走代理时先建 CONNECT 隧道、
// 再发一个最小 `GET /` 读到首字节，否则测出来的只是「本地代理响应快慢」。
//
// 为什么不再走 HTTPS（TCP + TLS + HEAD 响应头）：那是 Flutter 版曾经的做法，
// 实测同一条 104.16.1.1:443 是 2023ms，而 TCP 握手只有几十毫秒 —— 用户看到的
// 「延迟怎么这么大」就是这么来的。延迟阶段的职责是「筛掉连不上的候选」，
// 能不能真的拿到 HTTP 内容由速度阶段判定。
type latencyOutcome struct {
	// Latency 为 -1 表示不可用；>= 0 表示 TCP 握手（走代理时含一次真实往返）的毫秒数。
	Latency int64
	// Reason 为空表示可用；否则是可读的失败原因，直接落进 CSV 的 Reason 列。
	Reason string
}

// measureTCPLatency 测量「建连到目标」的往返耗时（返回 -1 表示失败）：
//   - 未配置代理：直接建 TCP 连接，计时 = 三次握手；
//   - 配置了代理：经代理建 CONNECT 隧道，再完成一次真实往返（发最小 GET、读 1 字节）。
//
// 只测「隧道建立成功」是不够的：那只反映本地代理响应快慢（约 1~2ms），
// 完全没有体现到境外目标的真实往返延迟。
func measureTCPLatency(
	ctx context.Context, ip, port string, timeout time.Duration,
) latencyOutcome {
	select {
	case <-ctx.Done():
		return latencyOutcome{Latency: -1, Reason: reasonCancelled}
	default:
	}

	target := net.JoinHostPort(ip, port)
	start := time.Now()

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
		return latencyOutcome{Latency: -1, Reason: describeTCPLatencyError(err, ctx)}
	}
	defer conn.Close()

	if proxyURL != nil {
		_ = conn.SetDeadline(time.Now().Add(timeout))
		if _, werr := conn.Write([]byte("GET / HTTP/1.0\r\nHost: " + target + "\r\n\r\n")); werr != nil {
			return latencyOutcome{Latency: -1, Reason: describeTCPLatencyError(werr, ctx)}
		}
		if _, rerr := io.ReadFull(conn, make([]byte, 1)); rerr != nil {
			return latencyOutcome{Latency: -1, Reason: describeTCPLatencyError(rerr, ctx)}
		}
	}

	return latencyOutcome{Latency: time.Since(start).Milliseconds()}
}

// describeTCPLatencyError 把延迟探测的失败原因翻成人话写进 CSV 的 Reason 列。
//
// 口径收敛为「连接超时 / 连接失败」两类：延迟阶段量的是 TCP 握手，
// 不涉及 TLS 证书、SNI、HTTP 状态码，把那些文案写进这一列就是误导。
// 代理侧失败单独分级（`代理隧道失败…`），否则用户会以为节点全挂了。
func describeTCPLatencyError(err error, ctx context.Context) string {
	if err == nil {
		return ""
	}
	if errors.Is(ctx.Err(), context.Canceled) {
		return reasonCancelled
	}

	var perr *proxyDialError
	if errors.As(err, &perr) {
		return perr.Error()
	}

	// 拨号阶段超时用 dialTimeout 报数：dial=5 连不上时说「>20s」是撒谎。
	var opErr *net.OpError
	if errors.As(err, &opErr) && opErr.Op == "dial" && isTimeoutErr(err) {
		return dialTimeoutReason()
	}
	if errors.Is(err, context.DeadlineExceeded) || isTimeoutErr(err) {
		return "连接超时"
	}
	return "连接失败"
}

// dialTimeoutReason 是「拨号阶段」超时的文案：TCP 握手都没完成，
// 此时真正的预算是 cfg.DialTimeout，报别的秒数会骗人。
func dialTimeoutReason() string {
	d := cfg.DialTimeout
	if d <= 0 {
		d = 5
	}
	if proxyURL != nil {
		return fmt.Sprintf("连接超时（>%ds，拨号到代理 %s）", d, proxyURL.Host)
	}
	return fmt.Sprintf("连接超时（>%ds，拨号阶段）", d)
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

// runLatencyStage 对 ipsToTest 做一轮「真的能用吗」的延迟测量。
//
// 口径与最初原版（censys-speedtest/src/pipeline.go 的 measureTCPLatency）一致：
// **只量 TCP 三次握手**（走代理时含一次真实往返），不做 TLS 握手、不看 HTTP 状态码。
//
// 为什么改回来：早期 Flutter 版把它换成「TCP + TLS + HEAD 响应头全通」，
// 同一条 104.16.1.1:443 实测 2023ms，而 TCP 握手只有几十毫秒 —— 用户看到的
// 「延迟怎么这么大」就是这么来的。延迟阶段的职责是「筛掉连不上的候选」，
// 能不能真拿到 HTTP 内容由速度阶段判定，两件事不该混在一个数里。
//
// 原地写入每个目标的 Latency；不可用的条目同时写入 Reason（`连接超时` / `连接失败`），
// 这样「只延迟」模式可以直接把它们写进 CSV 给用户看。
//
// [applyThreshold] 决定是否把超过 cfg.MaxLatency 的条目判为失败：
//   - 速度/一键模式传 true：阈值用于「筛掉高延迟候选」，让速度阶段少测几条；
//   - 只延迟模式传 false：用户点「延迟测试」是想看每条候选的真实延迟，
//     阈值会把大量跨境候选直接标成失败，看起来像「全挂了」。
func runLatencyStage(
	ctx context.Context, ipsToTest []*TestResult, clientPool *ClientPool, applyThreshold bool,
) []*TestResult {
	if len(ipsToTest) == 0 {
		fmt.Fprintln(os.Stderr, "没有找到待测试的 IP")
		return nil
	}

	// 延迟探测每条都要建连接，并发上限独立于速度阶段。
	dialTimeout := time.Duration(cfg.DialTimeout) * time.Second
	concurrency := cfg.MaxLatencyConcurrency
	if concurrency <= 0 {
		concurrency = 10
	}

	logf("")
	logf("   ----- 延迟测试 -----")
	logf("   探测方式: TCP 握手（老口径：能连上就算通过，不看 TLS / HTTP 状态码）")
	logf("   单条超时: %ds", cfg.DialTimeout)
	passed := NewSafeResults()
	totalIPs := int32(len(ipsToTest))
	var latencyDone int32
	var latencyWg sync.WaitGroup
	latencySem := make(chan struct{}, concurrency)

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

			port, perr := strconv.Atoi(result.Port)
			if perr != nil || port < 1 || port > 65535 {
				result.Latency = -1
				result.Reason = fmt.Sprintf("端口不合法: %q", result.Port)
				atomic.AddInt32(&latencyDone, 1)
				return
			}

			out := measureTCPLatency(ctx, result.IP, result.Port, dialTimeout)
			result.Latency = out.Latency
			cur := atomic.AddInt32(&latencyDone, 1)

			switch {
			case out.Latency < 0:
				result.Reason = out.Reason
				if result.Reason == "" {
					result.Reason = "延迟测试失败"
				}
				if !*quiet {
					logf("   [延迟 %d/%d] %s:%s 不可用：%s",
						cur, totalIPs, result.IP, result.Port, result.Reason)
				}
			case applyThreshold && cfg.MaxLatency > 0 && out.Latency > cfg.MaxLatency:
				result.Reason = fmt.Sprintf("延迟 %dms 超过阈值 %dms", out.Latency, cfg.MaxLatency)
				if !*quiet {
					logf("   [延迟 %d/%d] %s:%s %dms (超过阈值)",
						cur, totalIPs, result.IP, result.Port, out.Latency)
				}
			default:
				result.Reason = ""
				if !*quiet {
					logf("   [延迟 %d/%d] %s:%s %dms", cur, totalIPs, result.IP, result.Port, out.Latency)
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
		logf("   延迟测试完成，%d/%d 个 IP 可访问测速站（只延迟模式不按阈值筛选）",
			len(passedList), len(ipsToTest))
	} else if cfg.MaxLatency > 0 {
		logf("   延迟测试完成，%d/%d 个 IP 通过（阈值 %dms）", len(passedList), len(ipsToTest), cfg.MaxLatency)
	} else {
		logf("   延迟测试完成，%d/%d 个 IP 通过（未设阈值，只保留能访问测速站的）",
			len(passedList), len(ipsToTest))
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

	dialTimeout := time.Duration(cfg.DialTimeout) * time.Second
	downloadTimeout := time.Duration(cfg.DownloadTimeout) * time.Second
	// 延迟阶段与速度阶段共用同一个 ClientPool：同一个候选 ip:port 复用同一个
	// http.Client，速度阶段能直接吃到延迟阶段已经握过手的连接，不用二次 TLS。
	clientPool := NewClientPool(dialTimeout, downloadTimeout)

	passedList := runLatencyStage(ctx, ipsToTest, clientPool, true)
	if passedList == nil {
		// 一条都没通过延迟测试：与「只延迟」模式对齐，把失败明细落盘，
		// 让 Dart 侧在 code != 0 时仍能读到部分结果；返回值仍是 nil → 调用方 exit 1。
		writeLatencyFailureCSV(ipsToTest)
		return nil
	}

	logf("")
	logf("   ----- 速度测试 -----")
	logfSpeedQueueHint(len(passedList))

	sorted := runSpeedStage(ctx, passedList, clientPool)
	if sorted == nil {
		return nil
	}
	return sorted
}

// speedQueueHintThreshold 是「提示用户先筛一遍」的候选数量门槛。
const speedQueueHintThreshold = 10

// logfSpeedQueueHint 在候选偏多时给个耗时预期，避免用户以为卡死。
//
// 单条耗时下限 ≈ 预热 + 计量窗口（3s）+ 建连，上限则是「失败的目标等满超时」
// （downloadTimeout）。这里刻意报**上限**并写明「最多」：宁可高估也不要让用户
// 觉得「说 5 秒结果跑了 50 秒卡死了」；精确工期在候选质量未知时算不出来。
func logfSpeedQueueHint(n int) {
	if n <= speedQueueHintThreshold {
		return
	}
	logf("   提示: 共 %d 条进入测速，单条最多约 %ds（失败的目标会等满超时），"+
		"可先用「延迟测试」筛一遍再测速",
		n, cfg.DownloadTimeout)
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

// filterTargetsBySHA1 对 `ip:port` 清单跑阶段1（等价原版 runSHA1Filter，只是输入不是 Censys JSON）。
//
// 与原版逐条对齐：`GET http://ip:port`、读最多 maxResponseBytes 算 SHA1、5s 超时、
// 重试 1 次、并发 MaxSha1Concurrency；**不按端口预筛**（80 / 443 / 8443 一视同仁，
// 谁命中留谁）。原版的指纹是对**明文 HTTP** 响应体算的，443 走 TLS 拿到的是另一份
// 内容（实测同一台 CF 边缘：80 命中 108b6115…，443 是 f56c7076…），所以这里不做
// 「443 自动换 https」的花活——那会让哈希永远对不上。
func filterTargetsBySHA1(ctx context.Context, targets []*TestResult) []*TestResult {
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
	logf("▶ 阶段1/3：SHA1 指纹比对（-targets 清单）")
	logf("====================================================================")
	logf("   目标 SHA1: %s | 并发: %d | 候选: %d | 不按端口预筛", target, conc, len(targets))

	transport := &http.Transport{
		MaxIdleConns:        conc,
		MaxIdleConnsPerHost: conc,
		IdleConnTimeout:     30 * time.Second,
	}
	if proxyURL != nil {
		transport.Proxy = http.ProxyURL(proxyURL)
	}
	client := &http.Client{Timeout: shaHTTPTimeout, Transport: transport}
	defer transport.CloseIdleConnections()

	type shaTarget struct{ ip, port string }
	jobChan := make(chan shaTarget, 256)
	matched := NewSafeResults()
	var processed, failed int64
	var wg sync.WaitGroup

	for i := 0; i < conc; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range jobChan {
				select {
				case <-ctx.Done():
					return
				default:
				}
				var (
					sum     string
					lastErr error
				)
				url := "http://" + net.JoinHostPort(j.ip, j.port)
				for attempt := 0; attempt <= retryAttempts; attempt++ {
					sum, lastErr = fetchSHA1(ctx, client, url)
					if lastErr == nil {
						break
					}
				}
				cur := atomic.AddInt64(&processed, 1)
				switch {
				case lastErr != nil:
					atomic.AddInt64(&failed, 1)
					if !*quiet {
						logf("   [%d] %s:%s  网络错误", cur, j.ip, j.port)
					}
				case sum == target:
					if !*quiet {
						logf("   [%d] %s:%s  命中", cur, j.ip, j.port)
					}
					matched.Add(&TestResult{IP: j.ip, Port: j.port, Latency: -1})
				default:
					if !*quiet {
						logf("   [%d] %s:%s  指纹不匹配", cur, j.ip, j.port)
					}
				}
			}
		}()
	}
	for _, t := range targets {
		jobChan <- shaTarget{ip: t.IP, port: t.Port}
	}
	close(jobChan)
	wg.Wait()

	out := matched.Snapshot()
	logf("   [漏斗] 导入 %d → 指纹命中 %d（网络失败 %d）",
		len(targets), len(out), atomic.LoadInt64(&failed))
	return out
}

// loadTargets 读清单，并在 -sha1 时先过阶段1。全不命中按原版语义中止（exit 1）。
func loadTargets(ctx context.Context) ([]*TestResult, error) {
	targets, err := readSpeedTargets(*targetsFile)
	if err != nil {
		return nil, err
	}
	if !*sha1Filter || len(targets) == 0 {
		return targets, nil
	}
	kept := filterTargetsBySHA1(ctx, targets)
	if len(kept) == 0 {
		return nil, fmt.Errorf("阶段1 没有命中任何目标（检查 TargetSHA1Hash 与候选清单）")
	}
	return kept, nil
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
	// 自检模式把结果指到 os.DevNull：别对用户说「已写入 NUL」。
	if *resultCSV == os.DevNull {
		logf("   测试完成，共 %d 个 IP（自检模式，不落盘）", len(sorted))
	} else {
		logf("   测试完成，共 %d 个 IP，结果已写入 %s", len(sorted), *resultCSV)
	}
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
	// 自检只打印协议样例，不该产出产物：把结果文件指到 os.DevNull，
	// 免得在 cwd 里凭空生成 result.csv（真机 cwd 常不可写，还会多一行写盘失败）。
	*resultCSV = os.DevNull

	// 一行根证书自检：Android 上「系统池为空 → 靠 cert 目录补载」这条分支
	// 没有真机就验不了，真机跑 `-protocol-selftest` 即可看到走了哪条。
	systemRootCAs()
	logf("TLS 根证书判定: %s", rootCAState.describe())

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
	clientPool := NewClientPool(dialTimeout, downloadTimeout)

	// 与最初原版 runSpeedTest 一致：**先测 TCP 延迟、按 maxLatency 过滤，再测速**。
	// 只测速而不筛延迟，会让几百条连不通的候选全部走到下载阶段，
	// 既慢又给不出一句有用的失败原因。
	passed := runLatencyStage(ctx, targets, clientPool, true)
	if len(passed) == 0 {
		fmt.Fprintln(os.Stderr, "没有 IP 通过延迟测试")
		return nil
	}

	logSpeedPlan(len(passed))
	return runSpeedStage(ctx, passed, clientPool)
}

func logLatencyPlan(total int) {
	logf("")
	logf("====================================================================")
	logf("▶ 阶段2/2：延迟测试（只延迟模式）")
	logf("====================================================================")
	logf("   候选数量: %d | 并发: %d | 单条超时: %ds",
		total, cfg.MaxLatencyConcurrency, cfg.DialTimeout)
	if cfg.MaxLatency > 0 {
		logf("   延迟阈值: %dms（只延迟模式不据此淘汰，仅一键测试使用）", cfg.MaxLatency)
	} else {
		logf("   延迟阈值: 未设置")
	}
}

// runLatencyOnly 只跑延迟阶段，并把**全部**目标（含失败）写进 result.csv。
//
// 判定口径与速度测试一致：TCP 连通 + TLS/SNI 校验 + HTTP 响应头到达，
// 才算这个 ip:port 可用（详见 measureClientLatency）。
// 与只测速模式对齐：Speed 记 0，失败原因写进 Reason。
// 返回值 ok 表示「至少 1 条通过延迟测试且结果已落盘」；为 false 时调用方
// 应 os.Exit(1)，与 -only-speed 的「没有可用结果」口径保持一致。
// 即使全部失败，失败明细也照旧写进 result.csv，便于排查。
func runLatencyOnly(
	ctx context.Context, targets []*TestResult,
) (results []*TestResult, ok bool) {
	logLatencyPlan(len(targets))

	dialTimeout := time.Duration(cfg.DialTimeout) * time.Second
	downloadTimeout := time.Duration(cfg.DownloadTimeout) * time.Second
	clientPool := NewClientPool(dialTimeout, downloadTimeout)

	// 忽略返回值：失败项也要进 CSV，所以直接复用被原地写好的 targets。
	_ = runLatencyStage(ctx, targets, clientPool, false)

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

const proxyProbeTimeout = 800 * time.Millisecond

// probeProxy 在开测前 TCP 探一次代理端口，几百毫秒超时即可。
//
// 目的不是验证代理能不能出网，而是排除「代理根本没在跑」这种最常见的
// 一脚踩空：配了 httpProxy 却连不上时，所有目标会一律失败，用户从结果里
// 完全看不出是代理的锅。这种情况必须立刻报出来并以 exit 2 退出，
// 不能伪装成「所有节点都失败」。
func probeProxy(ctx context.Context, addr string) error {
	probeCtx, cancel := context.WithTimeout(ctx, proxyProbeTimeout)
	defer cancel()
	d := &net.Dialer{Timeout: proxyProbeTimeout}
	conn, err := d.DialContext(probeCtx, "tcp", addr)
	if err != nil {
		return fmt.Errorf("%s %s", addr, describeProxyReason(err))
	}
	conn.Close()
	return nil
}

// logEffectiveConfig 打印一行紧凑的「生效配置」，用户截图就能定位环境问题。
func logEffectiveConfig() {
	proxyDesc := "直连"
	if proxyURL != nil {
		proxyDesc = "经代理 " + proxyURL.String()
	}
	speedURL := strings.TrimSpace(cfg.SpeedTestURL)
	if speedURL == "" {
		speedURL = "（未配置，延迟测试无法进行）"
	}
	logf("   生效配置: 测速代理=%s | 测速地址=%s | dialTimeout=%ds | downloadTimeout=%ds | maxLatency=%dms",
		proxyDesc, speedURL, cfg.DialTimeout, cfg.DownloadTimeout, cfg.MaxLatency)
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
	logEffectiveConfig()
	if cfg.Insecure || *insecure {
		logf("   ⚠️ TLS 证书校验已关闭（--insecure / config.insecure=true）")
	}

	// 测速地址是延迟与测速两个阶段的唯一探测入口，空着就没法判「能不能用」。
	if strings.TrimSpace(cfg.SpeedTestURL) == "" {
		fmt.Fprintln(os.Stderr, "❌ 配置里没有 speedTestURL：延迟测试与测速都要访问该地址，无法进行")
		fmt.Fprintln(os.Stderr, "   请在设置页「线路与代理 → 测速地址」填一个可用的文件直链后重试（退出码 2）")
		os.Exit(2)
	}

	// 配了测速代理就先确认它活着：代理没起来时「所有目标都失败」是假象，
	// 必须立刻说清楚并以 exit 2 退出（参数/环境问题），不写 CSV、不当成结果。
	if proxyURL != nil {
		if perr := probeProxy(ctx, proxyURL.Host); perr != nil {
			fmt.Fprintf(os.Stderr, "❌ 测速代理不可用：%v\n", perr)
			fmt.Fprintln(os.Stderr,
				"   请在设置页「线路与代理 → 测速代理」清空该地址（留空=直连），或先启动代理后重试。")
			fmt.Fprintln(os.Stderr, "   （退出码 2：环境问题，不是「所有节点都失败」）")
			os.Exit(2)
		}
		logf("   ✅ 测速代理可达: %s", proxyURL.Host)
	}

	if *onlySpeed {
		if *targetsFile == "" {
			fmt.Fprintln(os.Stderr, "-only-speed 需要配合 -targets <文件> 使用")
			os.Exit(2)
		}
		targets, terr := loadTargets(ctx)
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
		targets, terr := loadTargets(ctx)
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

	// 带 -targets 且没有 -only-*：一键测试。带 -sha1 时先过指纹阶段，
	// 然后是延迟 + 速度（完整三阶段，与最初原版一致）。
	if *targetsFile != "" {
		targets, terr := loadTargets(ctx)
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
