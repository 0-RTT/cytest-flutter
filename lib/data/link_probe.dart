import 'dart:async';
import 'dart:io';

import '../core/idna.dart';

// ---------------------------------------------------------------------------
// 全局常量（设计 §12：**全部集中在此文件顶部**，T03 的 PortPool / Runner 直接引用，
// 不允许在别处再定义一份同口径的常量）
// ---------------------------------------------------------------------------

/// 延迟探测并发数。
/// Kotlin 出处：`LinkTestLimits.kt` → `LATENCY_PARALLEL = 6`
/// （设计文档 §1 第 8 行引用；对照工程 `D:/cytest-app`）。
///
/// 6 路 × 12s 上界是可接受的发热/带宽；再高会让死链把队列堵得更久。
const int kLatencyParallel = 6;

/// 测速并发数。
/// Kotlin 出处：`LinkTestLimits.kt` → `PARALLEL = 2`（设计 §1 第 9 行）。
///
/// 带宽是共享资源：并发 >2 测出来的是「总带宽被瓜分后的残值」，横比失真。
const int kSpeedParallel = 2;

/// 端口池基址。
/// Kotlin 出处：`LinkTestLimits.kt` → `PORT_BASE`，分配算法见
/// `LinkTestController.kt:296-308`（`ServerSocket.bind` 逐个验证空闲）。
const int kPortBase = 20000;

/// 端口池跨度。
/// Kotlin 出处：`LinkTestLimits.kt` → `PORT_SPAN`，同上 `LinkTestController.kt:296-308`。
const int kPortSpan = 500;

/// 批量启动后等待**全部**入站端口就绪的上限。
/// Kotlin 出处：`XrayController.kt:91-136` 与 `:199-217`（`awaitPorts` 的 12s）。
///
/// 单项 8s 不够：20 个入站要在同一进程里逐个 bind 并各自建立到节点的 outbound，
/// 冷启动时最后几个端口常在 9~11s 才起。
const Duration kPortReadyTimeout = Duration(seconds: 12);

/// 结果每累积多少条刷新一次 UI。
/// Kotlin 出处：`LinkTestLimits.kt` → `RESULT_FLUSH_EVERY = 8`（设计 §1 第 14 行）。
///
/// 6 路并发下逐条 setState 会明显抖动。
const int kResultFlushEvery = 8;

/// 吞吐预热字节数（256 KiB）。
/// Kotlin 出处：`LinkProbe.kt:110-119`（伴生对象常量块）→ `WARMUP_BYTES`。
///
/// 不预热会被 TCP 慢启动严重低估 —— 测出来的是「握手速度」而不是线路速度。
const int kWarmupBytes = 262144;

/// 吞吐窗口时长（毫秒）。
/// Kotlin 出处：`LinkProbe.kt:110-119` → `WINDOW_MS`。
const int kBudgetMs = 3000;

/// 吞吐窗口字节上限（64 MiB）。
/// Kotlin 出处：`LinkProbe.kt:110-119` → `MAX_BYTES`。
///
/// 防止一条极快线路在 3 秒里读几百 MB（移动网络限流 / 发热）。
const int kMaxBytes = 67108864;

/// 吞吐窗口时长下限（毫秒）。
/// Kotlin 出处：`LinkProbe.kt:110-119` → `MIN_WINDOW_MS`。
///
/// 窗口不足 1s 时按 1s 计，避免几十毫秒的窗口把结果放大几十倍。
const int kMinWindowMs = 1000;

/// 建连超时。
/// Kotlin 出处：`LinkProbe.kt:117-119` → connectTimeout。
const Duration kConnectTimeout = Duration(seconds: 8);

/// 延迟探测的整体死线（read + call）。
/// Kotlin 出处：`LinkProbe.kt:117-119` → `READ_TIMEOUT_MS = 12000`。
const Duration kLatencyTimeout = Duration(seconds: 12);

/// 速度探测的整体死线。
/// Kotlin 出处：`LinkProbe.kt:117-119` → `SPEED_READ_TIMEOUT_MS = 25000`。
///
/// 25s = 「3s 窗口 + 慢启动 + 建连」的合理上界。
const Duration kSpeedTimeout = Duration(seconds: 25);

/// 默认测速地址。
///
/// 注意 `е` 是**西里尔字母 U+0435**（不是拉丁 e），所以必须走 [probeUri] 做
/// punycode 转换，否则 `HttpClient` 会发出错误主机名（设计 §9 R4）。
const String kDefaultSpeedUrl = 'https://е.eu.org/300.zip';

/// 没读到任何字节时的固定文案（与 Kotlin `LinkProbe` 一致，UI 直接展示）。
const String kProbeNoData = '没有读到数据';

/// 预热未完成的固定文案。
const String kProbeWarmupIncomplete = '预热未完成（3s 内读不满 256 KiB）';

/// 把探测期间的异常翻译成用户能读懂的一句话。
///
/// 保留原文（`e.message`）而不是整段 `toString()`：`SocketException` 的
/// `toString()` 会带「OS Error: ... errno = 111」这类噪音，展示在单行列表里
/// 会把真正的原因挤掉。
String humanizeProbeError(Object error) {
  if (error is SocketException) {
    final msg = error.message;
    return msg.isEmpty ? '连接失败' : '连接失败：$msg';
  }
  if (error is TimeoutException) return '超时';
  if (error is HandshakeException) {
    final msg = error.message;
    return msg.isEmpty ? 'TLS 握手失败' : 'TLS 握手失败：$msg';
  }
  if (error is HttpException) {
    final msg = error.message;
    return msg.isEmpty ? 'HTTP 错误' : 'HTTP 错误：$msg';
  }
  if (error is FormatException) return '地址非法：${error.message}';
  return error.toString();
}

/// 一次吞吐窗口的采样结果。
class SpeedSample {
  const SpeedSample({required this.windowBytes, required this.windowMs});

  /// 窗口内读到的字节数（不含预热）。
  final int windowBytes;

  /// 窗口时长（毫秒，已按 `minWindowMs` 兜底）。
  final int windowMs;

  /// MiB/s（1024² 字节为一 MiB，与 Kotlin 一致，不是 Mbps）。
  double get mibPerSec => windowBytes / (1024 * 1024) / (windowMs / 1000);
}

/// 吞吐累加器：**纯计算，不碰网络**，因此可以用「喂字节 + 假时间」精确单测。
///
/// 常量照搬 Kotlin `LinkProbe` 伴生对象：
/// - [warmupBytes] 256 KiB：不预热会被 TCP 慢启动严重低估，测出来的是「握手速度」；
/// - [budgetMs] 3000：窗口过短噪声大；
/// - [maxBytes] 64 MiB：防止一条极快线路把 3 秒读成几百 MB（移动网络限流/发热）；
/// - [minWindowMs] 1000：窗口不足 1 秒时按 1 秒计，避免几十毫秒的窗口把结果放大几十倍。
class SpeedMeter {
  SpeedMeter({
    this.warmupBytes = kWarmupBytes,
    this.budgetMs = kBudgetMs,
    this.maxBytes = kMaxBytes,
    this.minWindowMs = kMinWindowMs,
  });

  /// 预热阈值（字节）。
  final int warmupBytes;

  /// 开窗后的时间预算（毫秒）。
  final int budgetMs;

  /// 窗口内累计字节上限。
  final int maxBytes;

  /// 窗口时长下限（毫秒）。
  final int minWindowMs;

  /// 首字节时刻（毫秒，相对探测开始）；-1 表示还没读到任何字节。
  int firstByteMs = -1;

  /// 累计读到的总字节数（含预热），仅用于诊断。
  int total = 0;

  int _warmBytes = 0;
  int _windowBytes = 0;
  int _windowStartMs = 0;
  int _lastElapsedMs = 0;
  bool _warmDone = false;

  /// 预热是否已满。
  bool get warmupDone => _warmDone;

  /// 窗口内字节是否已达上限（达到即停）。
  bool get reachedMaxBytes => _warmDone && _windowBytes >= maxBytes;

  /// 窗口时长是否已用满预算（达到即停）。
  bool get reachedBudget =>
      _warmDone && (_lastElapsedMs - _windowStartMs) >= budgetMs;

  /// 当前窗口时长（毫秒，未兜底）。
  int get windowMs => _warmDone ? _lastElapsedMs - _windowStartMs : 0;

  /// 当前窗口内字节数。
  int get windowBytes => _windowBytes;

  /// 累加一个 chunk。
  ///
  /// [elapsedMs] 是「相对探测开始」的毫秒数，由调用方给（这样可注入假时间）。
  /// 若一个 chunk 跨越预热阈值，则**补齐预热后的剩余部分**计入窗口，
  /// 窗口起点取该 chunk 的到达时刻——这是对「窗口从预热完成那一刻开始」的
  /// 最诚实近似（读流的最小粒度就是 chunk，没有更细的时间信息）。
  void onChunk(int bytes, int elapsedMs) {
    if (bytes <= 0) return;
    _lastElapsedMs = elapsedMs;
    if (firstByteMs < 0) firstByteMs = elapsedMs;
    total += bytes;

    if (!_warmDone) {
      final need = warmupBytes - _warmBytes;
      if (bytes < need) {
        _warmBytes += bytes;
        return;
      }
      _warmBytes = warmupBytes;
      _warmDone = true;
      _windowStartMs = elapsedMs;
      _windowBytes += bytes - need;
      return;
    }
    _windowBytes += bytes;
  }

  /// 采样；预热未完成或窗口内没有数据时返回 null（= 「未测」，不是 0）。
  SpeedSample? sample() {
    if (!_warmDone || _windowBytes <= 0) return null;
    final raw = _lastElapsedMs - _windowStartMs;
    return SpeedSample(
      windowBytes: _windowBytes,
      windowMs: raw < minWindowMs ? minWindowMs : raw,
    );
  }
}

/// 单次探测的返回值（内核层，与 UI 无关）。
class LinkProbeOutcome {
  const LinkProbeOutcome({
    required this.ttfbMs,
    this.speedMib,
    this.error,
    required this.elapsedMs,
    this.cancelled = false,
  });

  /// 首字节时间（TTFB），-1 = 没读到首字节。
  final int ttfbMs;

  /// 吞吐（MiB/s），null = 未测 / 预热未完成（**与 0.0 严格区分**，差异 D2）。
  final double? speedMib;

  /// 失败原因，null = 成功。
  final String? error;

  /// 本次探测实际耗时（诊断用）。
  final int elapsedMs;

  /// 是否因用户取消而中断。
  final bool cancelled;

  /// 可用判定：没有错误且不是取消。
  bool get ok => error == null && !cancelled;

  /// 延迟是否已知（TTFB 读到了）。
  bool get latencyKnown => ttfbMs >= 0;

  /// 是否真的测出了速度（>0）。UI 的「未测」判定就用它。
  bool get hasSpeed => ok && (speedMib ?? 0) > 0;

  /// 失败结果的简写。
  factory LinkProbeOutcome.failure(String error, int elapsedMs) =>
      LinkProbeOutcome(ttfbMs: -1, error: error, elapsedMs: elapsedMs);

  /// 取消结果的简写。
  factory LinkProbeOutcome.cancelledAt(int elapsedMs) => LinkProbeOutcome(
        ttfbMs: -1,
        elapsedMs: elapsedMs,
        cancelled: true,
      );

  @override
  String toString() => 'LinkProbeOutcome(ttfb=$ttfbMs, speed=$speedMib, '
      'error=$error, elapsed=$elapsedMs, cancelled=$cancelled)';
}

/// 单节点探测：通过本机某个 Xray 入站口（[localPort]）发真实 HTTPS 请求。
///
/// 与旧「测进程启动耗时」的实现完全不同（设计 §0）：
/// - [latency] 测 **TTFB**（从发起请求到读到第一个字节），不是 ICMP、不是 TCP 握手；
/// - [speed] 测 **首字节后 3s / 64MiB 窗口的吞吐**。
///
/// 本类只依赖 `dart:io`，可被纯 Dart 单测覆盖；不 import Flutter。
class LinkProbe {
  LinkProbe({
    this.speedUrl = kDefaultSpeedUrl,
    required this.localPort,
    this.connectTimeout = kConnectTimeout,
    this.latencyTimeout = kLatencyTimeout,
    this.speedTimeout = kSpeedTimeout,
  });

  /// 测速地址（原始串，可能含 IDN 主机名）。
  final String speedUrl;

  /// 本机入站端口（Xray 批量配置里 127.0.0.1:[localPort]）。
  final int localPort;

  /// 建连超时（默认 [kConnectTimeout]，照搬 Kotlin 8s）。
  ///
  /// 做成**实例参数**而不是 `static const`：否则「超时分支」的单测必须真的等
  /// 12 秒/25 秒，测试会被拖成分钟级；注入短值后语义与默认口径完全一致。
  final Duration connectTimeout;

  /// 延迟探测的整体死线（默认 [kLatencyTimeout]，照搬 Kotlin 12s）。
  final Duration latencyTimeout;

  /// 速度探测的整体死线（默认 [kSpeedTimeout]，照搬 Kotlin 25s）。
  final Duration speedTimeout;

  HttpClient? _client;
  Timer? _watchdog;
  bool _cancelled = false;
  Uri? _uri;

  /// 是否已被 [cancel]（取消后不再发起新请求）。
  bool get cancelled => _cancelled;

  /// 解析并 ASCII 化后的目标地址（首次访问时计算，失败抛 [UnsupportedIdnException]）。
  ///
  /// 失败的解析结果不缓存：修好 speedUrl 后重建 LinkProbe 即可。
  Uri get uri => _uri ??= probeUri(speedUrl);

  /// 建一个走本机入站的 HttpClient。
  HttpClient _newClient() {
    final client = HttpClient()
      ..connectionTimeout = connectTimeout
      // findProxy 是 Dart 侧唯一的「强制走代理」手段：返回 'PROXY host:port'
      ..findProxy = (Uri _) => 'PROXY 127.0.0.1:$localPort';
    _client = client;
    return client;
  }

  /// 挂看门狗：Dart 的 `HttpClient` 没有 callTimeout，到点必须自己 `close(force)`。
  Timer _armWatchdog(HttpClient client, Duration limit) {
    _watchdog = Timer(limit, () {
      // close(force: true) 会让在途的 `await for` 立刻结束——这是 Dart 里
      // 中断正在读的响应的唯一可靠手段（`Future.timeout` 不回收 socket）。
      client.close(force: true);
    });
    return _watchdog!;
  }

  void _teardown(HttpClient client) {
    _watchdog?.cancel();
    _watchdog = null;
    client.close(force: true);
    if (identical(_client, client)) _client = null;
  }

  /// 测 TTFB。
  Future<LinkProbeOutcome> latency() async {
    final sw = Stopwatch()..start();
    final client = _newClient();
    _armWatchdog(client, latencyTimeout);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      final response = await request.close();
      if (_cancelled) {
        return LinkProbeOutcome.cancelledAt(sw.elapsedMilliseconds);
      }

      final code = response.statusCode;
      if (code < 200 || code >= 300) {
        // 丢掉 body，避免连接悬挂
        unawaited(response.drain<void>().catchError((Object _) {}));
        return LinkProbeOutcome.failure('HTTP $code', sw.elapsedMilliseconds);
      }

      await for (final chunk in response) {
        if (chunk.isEmpty) continue;
        final ttfb = sw.elapsedMilliseconds;
        return LinkProbeOutcome(ttfbMs: ttfb, elapsedMs: ttfb);
      }
      return LinkProbeOutcome.failure(kProbeNoData, sw.elapsedMilliseconds);
    } on Object catch (e) {
      if (_cancelled) {
        return LinkProbeOutcome.cancelledAt(sw.elapsedMilliseconds);
      }
      return LinkProbeOutcome.failure(
        humanizeProbeError(e),
        sw.elapsedMilliseconds,
      );
    } finally {
      _teardown(client);
    }
  }

  /// 测吞吐（TTFB 兼作延迟，与 Kotlin `LinkProbe.speed` 一致）。
  Future<LinkProbeOutcome> speed() async {
    final sw = Stopwatch()..start();
    final meter = SpeedMeter();
    final client = _newClient();
    _armWatchdog(client, speedTimeout);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      final response = await request.close();
      if (_cancelled) {
        return LinkProbeOutcome.cancelledAt(sw.elapsedMilliseconds);
      }

      final code = response.statusCode;
      if (code < 200 || code >= 300) {
        unawaited(response.drain<void>().catchError((Object _) {}));
        return LinkProbeOutcome.failure('HTTP $code', sw.elapsedMilliseconds);
      }

      await for (final chunk in response) {
        if (_cancelled) {
          return LinkProbeOutcome.cancelledAt(sw.elapsedMilliseconds);
        }
        // 只累加长度，绝不缓存：3s 窗口可能读几十 MB（设计 §3 背压）
        meter.onChunk(chunk.length, sw.elapsedMilliseconds);
        if (meter.reachedBudget || meter.reachedMaxBytes) break;
      }

      if (meter.firstByteMs < 0) {
        return LinkProbeOutcome.failure(kProbeNoData, sw.elapsedMilliseconds);
      }
      final sample = meter.sample();
      if (sample == null) {
        // 有首字节但没读完预热：速度记「未测」，不能记 0（差异 D2）
        return LinkProbeOutcome(
          ttfbMs: meter.firstByteMs,
          speedMib: null,
          error: kProbeWarmupIncomplete,
          elapsedMs: sw.elapsedMilliseconds,
        );
      }
      return LinkProbeOutcome(
        ttfbMs: meter.firstByteMs,
        speedMib: sample.mibPerSec,
        elapsedMs: sw.elapsedMilliseconds,
      );
    } on Object catch (e) {
      if (_cancelled) {
        return LinkProbeOutcome.cancelledAt(sw.elapsedMilliseconds);
      }
      return LinkProbeOutcome.failure(
        humanizeProbeError(e),
        sw.elapsedMilliseconds,
      );
    } finally {
      _teardown(client);
    }
  }

  /// 取消：置位 + 关客户端（在途 `await for` 立即结束）+ 停看门狗。
  ///
  /// 幂等，可重复调用。取消后本实例不应再被使用（新建一个即可）。
  void cancel() {
    _cancelled = true;
    _watchdog?.cancel();
    _watchdog = null;
    final client = _client;
    _client = null;
    client?.close(force: true);
  }
}
