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
///
/// **有意偏离原版**：Kotlin `LinkProbe` 这里是 `READ_TIMEOUT_MS = 12000`。
/// 改成 5s 的依据与代价（改回去之前请先读完这段）：
/// - 跨境单程 RTT 200~300ms 时，「TLS 握手 + 一次请求」正常在 1s 内完成，
///   5s 已经是 5 倍余量，正常节点不会因此变红；
/// - 而**端点不可达**（本功能会枚举多个候选端点）常常几百 ms 就建连失败，
///   真正拖满的是 DNS 卡死；12s × 3 个候选 = 36s，用户会以为程序卡死；
///   5s × 3 = 15s，仍在可接受范围；
/// - 代价：极慢但可用的节点（>5s 才回首字节）会被判失败 —— 这类节点在
///   实际使用中体验也已经不可接受。
///
/// 注意它比 [kConnectTimeout]（8s）更短：先到的是这条死线，这是**故意的**
/// 取舍（见 [LinkProbe._armWatchdog] 的超时标记，失败原因仍然显示「超时」，
/// 不会变成「连接被中断」这种看不懂的话）。
const Duration kLatencyTimeout = Duration(seconds: 5);

/// 速度探测的整体死线。
/// Kotlin 出处：`LinkProbe.kt:117-119` → `SPEED_READ_TIMEOUT_MS = 25000`。
///
/// 25s = 「3s 窗口 + 慢启动 + 建连」的合理上界。
const Duration kSpeedTimeout = Duration(seconds: 25);

/// 默认测速（**速度阶段**）地址：必须是「大文件」，否则 3s 窗口读不满。
///
/// 注意 `е` 是**西里尔字母 U+0435**（不是拉丁 e），所以必须走 [probeUri] 做
/// punycode 转换，否则 `HttpClient` 会发出错误主机名（设计 §9 R4）。
const String kDefaultSpeedUrl = 'https://е.eu.org/300.zip';

/// 默认**延迟阶段**地址：小端点、无 body、无跳转。
///
/// 为什么必须和 [kDefaultSpeedUrl] 分开（Bug B 的修法，见 [LinkProbe.latency]）：
/// - 300.zip 这类「下载大文件」的端点，首字节会被服务端/链路缓冲推迟，
///   与 v2rayN 用的 204 小端点不是同一个口径，读数天然偏大；
/// - 大文件端点常带 302（换 CDN 主机），跟随跳转会把第二套 DNS/CONNECT/TLS
///   一起算进 TTFB，读数再翻一倍。
///
/// `cp.cloudflare.com/generate_204` 是各大代理客户端（含 v2rayN）常用的
/// 连通性/延迟探测端点：固定 204、无 body、无跳转、全球 Anycast。
const String kDefaultLatencyUrl = 'https://cp.cloudflare.com/generate_204';

/// 延迟阶段的**候选端点链**（第一个必须与 [kDefaultLatencyUrl] 同一个值，
/// 这里直接引用常量，避免两处各写一份字面量后悄悄漂移）。
///
/// 为什么要候选：延迟口径绑在单一端点上，端点在国内被限流/被墙时，
/// 「端点不可达」会以和「节点全挂」一模一样的失败文案呈现，用户会误判。
/// 编排层（`LinkTestRunner`）在「整批一条都没拿到延迟」时按本表逐个重试，
/// 这样才分得清「端点坏」和「线路坏」。
///
/// 为什么是这两个：都是各大代理客户端常用的连通性探测端点，固定 204、
/// 无 body、无跳转，且分属两家 Anycast 网络（一家挂掉不代表另一家也挂）。
const List<String> kLatencyFallbackUrls = <String>[
  kDefaultLatencyUrl,
  'https://www.gstatic.com/generate_204',
];

/// 延迟阶段最多尝试几个候选端点（含用户配置的首选）。
///
/// 3 = 首选 + 2 次切换。上限是为了不让「所有端点都不可达」这个场景把整轮拖爆：
/// 单次尝试最坏 `ceil(N/kLatencyParallel) × kLatencyTimeout`，所以
/// - N ≤ 6：5s × 3 次 = 15s
/// - N = 8：ceil(8/6)=2 波 × 5s × 3 次 = 30s
/// （都远好于 12s 口径下的 36s / 72s。）
const int kLatencyMaxAttempts = 3;

/// 一次探测的分项计时（毫秒，相对探测开始；-1 = 该阶段没走到）。
///
/// 拆项的唯一目的：**下次有人说「延迟读数不对」时，日志能直接指出是哪一段慢**
/// —— 是建连（CONNECT/TLS）、是服务端压着不回响应头，还是响应头发了但 body
/// 迟迟不来。整段只留一个 TTFB 时，这三种情况在日志里长得一模一样。
///
/// 已知限制：`dart:io` 不暴露「CONNECT 隧道」与「TLS 握手」的分界，
/// 所以 [connectMs] 是这两段**合并**的结果，不要当成纯 TCP 建连。
class ProbeTimings {
  const ProbeTimings({
    this.connectMs = -1,
    this.headerMs = -1,
    this.firstByteMs = -1,
    this.redirects = 0,
  });

  /// 建连（CONNECT 隧道 + TLS 握手）完成时刻。
  final int connectMs;

  /// 响应头到达时刻（= 一个完整 HTTP 往返）。
  final int headerMs;

  /// 首个 body 字节到达时刻。
  final int firstByteMs;

  /// 本次实际跟随的跳转次数（延迟阶段恒为 0：**故意不跟随**）。
  final int redirects;

  /// 一行可读的分项（直接进日志）。
  String get summary => '建连=$connectMs 响应头=$headerMs 首字节=$firstByteMs '
      '跳转=$redirects';

  @override
  String toString() => 'ProbeTimings($summary)';
}

/// 没读到任何字节时的固定文案（与 Kotlin `LinkProbe` 一致，UI 直接展示）。
const String kProbeNoData = '没有读到数据';

/// 超时的固定文案。
///
/// 单独提成常量：看门狗掐断在途请求后抛出的是 `HttpException`（文本很难懂），
/// 靠 [LinkProbe] 内部的 `_timedOut` 标记改写成这一句，[humanizeProbeError]
/// 与重试判据都引用它，避免两处字面量各写一份。
const String kProbeTimeout = '超时';

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
  if (error is TimeoutException) return kProbeTimeout;
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

/// 探测失败的**结构化类别**。
///
/// 为什么不靠 [LinkProbeOutcome.error] 的字符串判断：文案随时会被改
/// （例如「超时」→「超时（5s 内未收到首字节）」），一改就会**静默改变业务行为**
/// ——候选端点切换和速度重试都依赖这个分类。文案是给人看的，类别是给逻辑看的，
/// 两者必须分开。
enum ProbeFailureKind {
  /// 没有失败。
  none,

  /// 死线到点（看门狗掐断在途请求）。**注意**：它只能证明「这么久没拿到首字节」，
  /// 可能是端点坏，也可能是节点慢 —— 所以它**不能**当成「端点不可达」用。
  timeout,

  /// 建连类失败（拒绝连接 / 网络不可达 / DNS 失败）。
  connect,

  /// TLS 握手失败（证书 / SNI / 协议不匹配）。
  tlsHandshake,

  /// 服务端回了非 2xx。
  http,

  /// 有响应但没读到任何数据。
  noData,

  /// 其它（含脚本/参数错误）。
  other;

  /// 是否属于「建连类」失败 —— 这一类才能证明**端点或线路不可达**，
  /// 是候选端点切换的唯一合法依据（见 LinkTestRunner 的整批判定）。
  bool get isConnectLike =>
      this == ProbeFailureKind.connect || this == ProbeFailureKind.tlsHandshake;
}

/// 把异常归类成 [ProbeFailureKind]。
ProbeFailureKind classifyProbeFailure(Object error) {
  if (error is TimeoutException) return ProbeFailureKind.timeout;
  if (error is HandshakeException) return ProbeFailureKind.tlsHandshake;
  if (error is SocketException) return ProbeFailureKind.connect;
  if (error is HttpException) return ProbeFailureKind.http;
  return ProbeFailureKind.other;
}

/// 单次探测的返回值（内核层，与 UI 无关）。
class LinkProbeOutcome {
  const LinkProbeOutcome({
    required this.ttfbMs,
    this.speedMib,
    this.error,
    required this.elapsedMs,
    this.cancelled = false,
    this.timings,
    this.failureKind = ProbeFailureKind.none,
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

  /// 失败的结构化类别（成功/取消时是 [ProbeFailureKind.none]）。
  ///
  /// 逻辑判断只许看它，**不要**比较 [error] 的文案（文案会变）。
  final ProbeFailureKind failureKind;

  /// 是否踩到了死线。等价于 `failureKind == ProbeFailureKind.timeout`，
  /// 单独给一个 getter 是为了让调用点读起来更像人话。
  bool get timedOut => failureKind == ProbeFailureKind.timeout;

  /// 分项计时（诊断用，null = 该实现没采集）。
  ///
  /// 只用于日志/排障，**不参与任何判定**：判定仍然只看 [ttfbMs]/[error]/
  /// [cancelled]，否则「某一项没采到」就会变成「这条线路失败」。
  final ProbeTimings? timings;

  /// 可用判定：没有错误且不是取消。
  bool get ok => error == null && !cancelled;

  /// 延迟是否已知（TTFB 读到了）。
  bool get latencyKnown => ttfbMs >= 0;

  /// 是否真的测出了速度（>0）。UI 的「未测」判定就用它。
  bool get hasSpeed => ok && (speedMib ?? 0) > 0;

  /// 失败结果的简写。
  factory LinkProbeOutcome.failure(
    String error,
    int elapsedMs, {
    ProbeTimings? timings,
    ProbeFailureKind kind = ProbeFailureKind.other,
  }) =>
      LinkProbeOutcome(
        ttfbMs: -1,
        error: error,
        elapsedMs: elapsedMs,
        timings: timings,
        failureKind: kind,
      );

  /// 取消结果的简写。
  factory LinkProbeOutcome.cancelledAt(int elapsedMs) => LinkProbeOutcome(
        ttfbMs: -1,
        elapsedMs: elapsedMs,
        cancelled: true,
      );

  @override
  String toString() => 'LinkProbeOutcome(ttfb=$ttfbMs, speed=$speedMib, '
      'error=$error, elapsed=$elapsedMs, cancelled=$cancelled, '
      'kind=${failureKind.name}'
      '${timings == null ? '' : ', ${timings!.summary}'})';
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
    this.latencyUrl = kDefaultLatencyUrl,
    required this.localPort,
    this.connectTimeout = kConnectTimeout,
    this.latencyTimeout = kLatencyTimeout,
    this.speedTimeout = kSpeedTimeout,
  });

  /// 测速（速度阶段）地址（原始串，可能含 IDN 主机名）。
  final String speedUrl;

  /// 延迟阶段地址（原始串，可能含 IDN 主机名）。
  ///
  /// 默认 [kDefaultLatencyUrl]（204 小端点）。**不要**在延迟阶段复用
  /// [speedUrl]：大文件端点的首字节会被服务端缓冲推迟，且常带跨主机跳转，
  /// 两者叠加能让读数比 v2rayN 大一倍以上（Bug B）。
  final String latencyUrl;

  /// 本机入站端口（Xray 批量配置里 127.0.0.1:[localPort]）。
  final int localPort;

  /// 建连超时（默认 [kConnectTimeout]，照搬 Kotlin 8s）。
  ///
  /// 做成**实例参数**而不是 `static const`：否则「超时分支」的单测必须真的等
  /// 12 秒/25 秒，测试会被拖成分钟级；注入短值后语义与默认口径完全一致。
  final Duration connectTimeout;

  /// 延迟探测的整体死线（默认 [kLatencyTimeout]）。
  ///
  /// **非 final**：编排层按轮次改它 —— 首轮用 [kConnectTimeout]（8s）给
  /// 「连接被拒/DNS 失败」暴露的机会，重试轮用 [kLatencyTimeout]（5s）求快。
  /// 见 `LinkTestRunner._runLatencyStage`。
  Duration latencyTimeout;

  /// 速度探测的整体死线（默认 [kSpeedTimeout]，照搬 Kotlin 25s）。
  final Duration speedTimeout;

  HttpClient? _client;
  Timer? _watchdog;
  bool _cancelled = false;

  /// 看门狗是否已经开过枪。
  ///
  /// 用途：`close(force: true)` 掐断在途请求后，异常是
  /// `HttpException: Connection closed before full header was received` 之类，
  /// 经 [humanizeProbeError] 会变成「HTTP 错误：…」——用户读不出「是超时」。
  /// 尤其 [kLatencyTimeout]（5s）比 [kConnectTimeout]（8s）短，先到的一定是死线，
  /// 所以必须把这种中断翻译回「超时」，否则失败原因变得莫名其妙。
  bool _timedOut = false;
  Uri? _uri;
  Uri? _latencyUri;

  /// 是否已被 [cancel]（取消后不再发起新请求）。
  bool get cancelled => _cancelled;

  /// 解析并 ASCII 化后的**测速**地址（首次访问时计算，失败抛
  /// [UnsupportedIdnException]）。
  ///
  /// 失败的解析结果不缓存：修好 speedUrl 后重建 LinkProbe 即可。
  Uri get uri => _uri ??= probeUri(speedUrl);

  /// 解析并 ASCII 化后的**延迟**地址（同上）。
  ///
  /// 单独缓存：两个地址是两条独立的口径，混用一个字段会让「延迟用了哪个
  /// 端点」在日志里无从判断。
  Uri get latencyUri => _latencyUri ??= probeUri(latencyUrl);

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
    _timedOut = false;
    _watchdog = Timer(limit, () {
      // 置标记要在 close 之前：close 会同步/异步地让在途 future 失败，
      // 顺序反了就可能读到 false，失败原因又变回「连接被中断」。
      _timedOut = true;
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

  /// 测 TTFB（延迟阶段）。
  ///
  /// 口径与 v2rayN 的「真连接延迟」对齐，三项刻意收紧（Bug B 的修法）：
  /// 1. 目标用 [latencyUrl]（204 小端点），**不复用** [speedUrl] 的大文件端点；
  /// 2. `followRedirects = false` —— 跟随跳转时 SDK 会对 Location 重新
  ///    `_getConnection`（`_http/http_impl.dart:693` → `:3026`，再由 `:2520`
  ///    做 TLS 握手），等于把**第二套** DNS/CONNECT/TLS/请求全算进 TTFB，
  ///    读数天然翻倍。延迟只该量「一段」往返，跳转交给上层判断；
  /// 3. 耗时拆成「建连 / 响应头 / 首字节」三段记进 [LinkProbeOutcome.timings]，
  ///    以后再有人说读数不对，日志能直接指出是哪一段慢。
  ///
  /// 判定语义未变：3xx 与 204/205 都算**可达**（TTFB 取响应头时刻），
  /// 4xx/5xx 与「200 但一个字节都没有」仍是失败 —— 前者证明线路通不通，
  /// 后者证明端点有没有真的回数据，两件事不能混。
  Future<LinkProbeOutcome> latency() async {
    final sw = Stopwatch()..start();
    final client = _newClient();
    _armWatchdog(client, latencyTimeout);
    try {
      // ① 建连：CONNECT 隧道 + TLS 握手（dart:io 不暴露分界，只能合并计时）
      final request = await client.getUrl(latencyUri);
      final connectMs = sw.elapsedMilliseconds;
      request.followRedirects = false;
      // ② 一个完整 HTTP 往返（发请求 → 响应头）
      final response = await request.close();
      final headerMs = sw.elapsedMilliseconds;
      if (_cancelled) {
        return LinkProbeOutcome.cancelledAt(sw.elapsedMilliseconds);
      }

      final code = response.statusCode;
      final timings = ProbeTimings(
        connectMs: connectMs,
        headerMs: headerMs,
        // 不跟随跳转，所以 redirects 恒为 0；记录下来是为了日后有人把它
        // 改回 true 时，日志里能立刻看出「跳转数 > 0」这个异常。
        redirects: response.redirects.length,
      );

      if (code >= 400) {
        // 丢掉 body，避免连接悬挂
        unawaited(response.drain<void>().catchError((Object _) {}));
        return LinkProbeOutcome.failure(
          'HTTP $code',
          sw.elapsedMilliseconds,
          timings: timings,
          kind: ProbeFailureKind.http,
        );
      }

      // ③ 首字节（有 body 才有）
      var firstByteMs = -1;
      await for (final chunk in response) {
        if (chunk.isEmpty) continue;
        firstByteMs = sw.elapsedMilliseconds;
        break;
      }

      if (firstByteMs < 0) {
        // 204/205 与不跟随的 3xx：端点**按设计**没有 body，
        // TTFB 只能是响应头时刻。判成「没有读到数据」会把默认的
        // generate_204 端点整批判死（这是必须守住的一条）。
        final bodyless = code == HttpStatus.noContent ||
            code == HttpStatus.resetContent ||
            (code >= 300 && code < 400);
        if (!bodyless) {
          return LinkProbeOutcome.failure(
            kProbeNoData,
            sw.elapsedMilliseconds,
            timings: timings,
            kind: ProbeFailureKind.noData,
          );
        }
        return LinkProbeOutcome(
          ttfbMs: headerMs,
          elapsedMs: headerMs,
          timings: timings,
        );
      }

      return LinkProbeOutcome(
        ttfbMs: firstByteMs,
        elapsedMs: firstByteMs,
        timings: ProbeTimings(
          connectMs: connectMs,
          headerMs: headerMs,
          firstByteMs: firstByteMs,
          redirects: timings.redirects,
        ),
      );
    } on Object catch (e) {
      if (_cancelled) {
        return LinkProbeOutcome.cancelledAt(sw.elapsedMilliseconds);
      }
      // 看门狗先开枪时 e 会是「连接被中断」这类看不懂的话，见 [_timedOut]。
      if (_timedOut) {
        return LinkProbeOutcome.failure(
          kProbeTimeout,
          sw.elapsedMilliseconds,
          kind: ProbeFailureKind.timeout,
        );
      }
      return LinkProbeOutcome.failure(
        humanizeProbeError(e),
        sw.elapsedMilliseconds,
        kind: classifyProbeFailure(e),
      );
    } finally {
      _teardown(client);
    }
  }

  /// 测吞吐（TTFB 兼作延迟，与 Kotlin `LinkProbe.speed` 一致）。
  ///
  /// 与延迟阶段的差异是**故意的**：这里继续跟 [speedUrl]（大文件）并
  /// `followRedirects = true` —— 吞吐需要真的读到 body，很多大文件端点会
  /// 先 302 到就近 CDN，不跟随就永远测不出速度。所以 speed 阶段的 TTFB
  /// 口径比延迟阶段「脏」（含跳转），**不能拿它覆盖已有的延迟读数**，
  /// 只在「没测过延迟」（speed-only 模式）时才兼作延迟，见
  /// `LinkTestRunner._applyOutcome`。
  ///
  /// 会做**一次**连接级重试：XHTTP 这类多路复用传输，服务端常把建链后的
  /// 第一条连接直接关掉（实测 `run0` 必失败、`run1` 正常）。判据很窄——
  /// 只有「一个字节都没读到」且不是超时 / HTTP 状态错误才重试，
  /// 避免把死链的等待时间翻倍、也不干扰正常测速的读数。
  Future<LinkProbeOutcome> speed() async {
    final first = await _speedOnce();
    if (_shouldRetrySpeed(first)) return _speedOnce();
    return first;
  }

  bool _shouldRetrySpeed(LinkProbeOutcome o) {
    if (o.cancelled || o.error == null) return false;
    if (o.latencyKnown) return false; // 已经读到数据，属于真实结果/预热不足
    // 全部按**结构化类别**判断，不看文案：
    // 服务端已经明确回过状态码 → 不是建链抖动，重试没意义；
    // 超时 → 重试只会把等待时间翻倍（这里是最容易被文案改动搞坏的一处，
    // 以前写的是 `e == '超时'`，改文案就会静默变成「超时也重试」）。
    if (o.failureKind == ProbeFailureKind.http) return false;
    if (o.timedOut) return false;
    return true;
  }

  Future<LinkProbeOutcome> _speedOnce() async {
    final sw = Stopwatch()..start();
    final meter = SpeedMeter();
    final client = _newClient();
    _armWatchdog(client, speedTimeout);
    try {
      final request = await client.getUrl(uri);
      final connectMs = sw.elapsedMilliseconds;
      request.followRedirects = true;
      final response = await request.close();
      final headerMs = sw.elapsedMilliseconds;
      if (_cancelled) {
        return LinkProbeOutcome.cancelledAt(sw.elapsedMilliseconds);
      }

      final code = response.statusCode;
      if (code < 200 || code >= 300) {
        unawaited(response.drain<void>().catchError((Object _) {}));
        return LinkProbeOutcome.failure(
          'HTTP $code',
          sw.elapsedMilliseconds,
          timings: ProbeTimings(
            connectMs: connectMs,
            headerMs: headerMs,
            redirects: response.redirects.length,
          ),
          kind: ProbeFailureKind.http,
        );
      }

      await for (final chunk in response) {
        if (_cancelled) {
          return LinkProbeOutcome.cancelledAt(sw.elapsedMilliseconds);
        }
        // 只累加长度，绝不缓存：3s 窗口可能读几十 MB（设计 §3 背压）
        meter.onChunk(chunk.length, sw.elapsedMilliseconds);
        if (meter.reachedBudget || meter.reachedMaxBytes) break;
      }

      final timings = ProbeTimings(
        connectMs: connectMs,
        headerMs: headerMs,
        firstByteMs: meter.firstByteMs,
        redirects: response.redirects.length,
      );

      if (meter.firstByteMs < 0) {
        return LinkProbeOutcome.failure(
          kProbeNoData,
          sw.elapsedMilliseconds,
          timings: timings,
          kind: ProbeFailureKind.noData,
        );
      }
      final sample = meter.sample();
      if (sample == null) {
        // 有首字节但没读完预热：速度记「未测」，不能记 0（差异 D2）
        return LinkProbeOutcome(
          ttfbMs: meter.firstByteMs,
          speedMib: null,
          error: kProbeWarmupIncomplete,
          elapsedMs: sw.elapsedMilliseconds,
          timings: timings,
        );
      }
      return LinkProbeOutcome(
        ttfbMs: meter.firstByteMs,
        speedMib: sample.mibPerSec,
        elapsedMs: sw.elapsedMilliseconds,
        timings: timings,
      );
    } on Object catch (e) {
      if (_cancelled) {
        return LinkProbeOutcome.cancelledAt(sw.elapsedMilliseconds);
      }
      if (_timedOut) {
        return LinkProbeOutcome.failure(
          kProbeTimeout,
          sw.elapsedMilliseconds,
          kind: ProbeFailureKind.timeout,
        );
      }
      return LinkProbeOutcome.failure(
        humanizeProbeError(e),
        sw.elapsedMilliseconds,
        kind: classifyProbeFailure(e),
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
