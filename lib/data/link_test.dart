import 'dart:async';
import 'dart:io';

import '../core/semaphore.dart';
import 'link_probe.dart';
import 'vless.dart';
import 'xray.dart';

// ---------------------------------------------------------------------------
// 模型（一次运行的快照 + 单条结果）
// ---------------------------------------------------------------------------

/// 测速模式。
///
/// - [latency]：只测 TTFB，最快；
/// - [speed]：直接测速（速度探测的 TTFB 兼作延迟）；
/// - [auto]：先测延迟，**只对有响应者**测速，并保留延迟阶段的数值 —— 省掉对死链的
///   3s 空转，是默认推荐路径。
enum LinkTestMode { latency, speed, auto }

/// 单条结果的状态机。
///
/// ```
/// pending ──派发──▶ running ──成功──▶ done
///                    ├──失败(error != null)──▶ failed
///                    └──用户取消────────────▶ cancelled
/// pending ──取消（未派发）──────────────────▶ cancelled
/// ```
/// `done/failed/cancelled` 为终态；「重测」= 新建一次 run，不是原地改状态。
enum ProbeState { pending, running, done, failed, cancelled }

/// 单条结果。
///
/// 单条探测结果。**只有 [speedMib] 可空**（null = 未测，≠0）：
/// `null` = 未测（预热未完成 / 未进速度阶段），与「测出 0 MiB/s」严格区分，
/// 否则排序会把未测项当成「最慢」。
class LinkTestResult {
  const LinkTestResult({
    required this.link,
    required this.name,
    required this.host,
    required this.port,
    this.latencyMs = -1,
    this.speedMib,
    this.error,
    this.elapsedMs = 0,
    this.state = ProbeState.pending,
    this.failureKind = ProbeFailureKind.none,
  });

  /// 原始链接（去重键）。
  final String link;

  /// 显示名：取的 `#remark`，缺省用 `host:port`。
  final String name;

  /// 目标主机（**必须有值才能测**；非法链接这里是空串）。
  final String host;

  /// 目标端口（非法链接是 0）。
  final int port;

  /// TTFB（ms），-1 = 未知。
  final int latencyMs;

  /// 吞吐（MiB/s），null = 未测。
  final double? speedMib;

  /// 失败原因，null = 成功。
  final String? error;

  /// 本次探测实际耗时（诊断用）。
  final int elapsedMs;

  /// 状态机当前状态。
  final ProbeState state;

  /// 失败的结构化类别（成功/取消/未测时是 [ProbeFailureKind.none]）。
  ///
  /// 候选端点切换的判定只读它，**不读 [error] 的文案**：文案一改，
  /// 行为就跟着变，这种退化连测试都看不出来（QA 专门提过这一点）。
  ///
  /// 不落盘：它是「本轮为什么失败」的诊断信息，历史记录里重新计算没有意义。
  final ProbeFailureKind failureKind;

  /// 本条失败是否属于**踩到死线**（[kLatencyTimeout]/[kSpeedTimeout] 内没拿到首字节）。
  ///
  /// 由 [failureKind] 派生，不单独存一份 —— 两个字段一旦允许各自赋值，就会
  /// 出现「`timedOut == true` 但类别是 connect」这种自相矛盾的行。
  ///
  /// 为什么要用标志位而不是让调用方去比 [error] 的文案：延迟阶段要据此区分
  /// 「端点坏」（建连类失败，该换端点）与「线路慢」（超时，换端点也只是再等
  /// 一轮），而文案是随时会改给人看的东西 —— 一旦有人把 [kProbeTimeout] 从
  /// 「超时」改成「超时（5s 内未收到首字节）」，所有基于字符串比较的判定都会
  /// **静默**失效。标志位不受文案影响。
  ///
  /// 语义边界（不许和别的概念混）：
  /// - 它**不参与** [ok] / [hasSpeed] / [latencyKnown] —— 那些是「可用性」口径；
  /// - 超时一定伴随 `error != null`（必然 `ok == false`），但 `ok == false`
  ///   不代表超时（也可能是连接失败 / 预检失败）；
  /// - 预检失败（[host] 为空）永远不是超时。
  bool get timedOut => failureKind == ProbeFailureKind.timeout;

  /// 结果 key：`host:port`（节点按顺序入列时用它反查下标）。
  String get key => host.isEmpty ? link : '$host:$port';

  /// 是否可用：没有错误且不是取消态。
  bool get ok => error == null && state != ProbeState.cancelled;

  /// 延迟是否已知。
  bool get latencyKnown => latencyMs >= 0;

  /// 是否测出了速度（>0）。UI 的「未测」判定用它，不要用 `speedMib != 0`。
  bool get hasSpeed => ok && (speedMib ?? 0) > 0;

  /// 复制并覆盖部分字段。
  ///
  /// ⚠️ 已知限制：所有参数用 `??`，因此**无法把 [error] 清回 null**
  /// （传 `error: null` 等于「不改」）。当前流程踩不到——失败项不会进速度阶段，
  /// 也就没有「先失败后成功」的覆盖需求。**将来做「重测单条」时必须先改成
  /// 显式哨兵**（例如 `Object? error = _sentinel`），否则旧错误会残留，
  /// 结果看起来「失败但又有速度」。
  LinkTestResult copyWith({
    int? latencyMs,
    double? speedMib,
    String? error,
    int? elapsedMs,
    ProbeState? state,
    ProbeFailureKind? failureKind,
  }) =>
      LinkTestResult(
        link: link,
        name: name,
        host: host,
        port: port,
        latencyMs: latencyMs ?? this.latencyMs,
        speedMib: speedMib ?? this.speedMib,
        error: error ?? this.error,
        elapsedMs: elapsedMs ?? this.elapsedMs,
        state: state ?? this.state,
        // 注意：[failureKind] 可以传 `ProbeFailureKind.none` 显式复位
        // （`none != null`），所以「失败后成功」时能正确清掉旧类别，
        // 不像 [error] 那样受 `??` 限制。`timedOut` 是它的派生 getter，一并复位。
        failureKind: failureKind ?? this.failureKind,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'link': link,
        'name': name,
        'host': host,
        'port': port,
        'latencyMs': latencyMs,
        'speedMib': speedMib,
        'error': error,
        'elapsedMs': elapsedMs,
        'state': state.name,
        // 落盘的旧字段名保留 `timedOut`（历史文件兼容），
        // 但值由类别派生，不再单独维护一份布尔。
        'timedOut': timedOut,
        'failureKind': failureKind.name,
      };

  static LinkTestResult fromJson(Map<String, dynamic> json) => LinkTestResult(
        link: (json['link'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        host: (json['host'] as String?) ?? '',
        port: (json['port'] as num?)?.toInt() ?? 0,
        latencyMs: (json['latencyMs'] as num?)?.toInt() ?? -1,
        speedMib: (json['speedMib'] as num?)?.toDouble(),
        error: json['error'] as String?,
        elapsedMs: (json['elapsedMs'] as num?)?.toInt() ?? 0,
        state: _stateFromName(json['state'] as String?),
        // 旧的历史文件里没有这两个键：类别缺省 none。
        // 兼容只写过 `timedOut: true` 的中间版本：读到一个裸 true 也归成超时，
        // 这样历史记录里的「超时」不会因为字段演进变成「未知原因」。
        failureKind: _failureKindFromJson(json),
      );

  @override
  String toString() =>
      'LinkTestResult($name, ${state.name}, ttfb=$latencyMs, speed=$speedMib)';
}

/// 从历史 JSON 里读出失败类别（同时兼容 `failureKind` 与旧的 `timedOut`）。
ProbeFailureKind _failureKindFromJson(Map<String, dynamic> json) {
  final name = json['failureKind'] as String?;
  if (name != null) {
    for (final kind in ProbeFailureKind.values) {
      if (kind.name == name) return kind;
    }
  }
  if (json['timedOut'] == true) return ProbeFailureKind.timeout;
  return ProbeFailureKind.none;
}

ProbeState _stateFromName(String? name) {
  for (final state in ProbeState.values) {
    if (state.name == name) return state;
  }
  return ProbeState.pending;
}

/// 一次运行的聚合。
class LinkTestRun {
  const LinkTestRun({
    required this.id,
    required this.createdAt,
    required this.mode,
    required this.results,
  });

  /// `createdAt` 的毫秒串，用作文件名。
  final String id;

  /// 创建时刻（毫秒时间戳）。
  final int createdAt;

  final LinkTestMode mode;

  final List<LinkTestResult> results;

  /// 可用条数（`ok`）。
  int get okCount => results.where((r) => r.ok).length;

  /// 最快速度（MiB/s），没有可用速度时返回 0。
  double get fastest => results.fold<double>(
        0,
        (best, r) =>
            (r.hasSpeed && (r.speedMib ?? 0) > best) ? r.speedMib! : best,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'createdAt': createdAt,
        'mode': mode.name,
        'results': results.map((r) => r.toJson()).toList(),
      };

  static LinkTestRun fromJson(Map<String, dynamic> json) => LinkTestRun(
        id: (json['id'] as String?) ?? '',
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        mode: _modeFromName(json['mode'] as String?),
        results: ((json['results'] as List?) ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(LinkTestResult.fromJson)
            .toList(growable: false),
      );
}

LinkTestMode _modeFromName(String? name) {
  for (final mode in LinkTestMode.values) {
    if (mode.name == name) return mode;
  }
  return LinkTestMode.auto;
}

/// 编排层抛给 UI 的可读错误（`toString()` 直接就是中文文案）。
///
/// 用它而不是 `Exception('...')`：UI 里 `'$e'` 会带 `Exception: ` 前缀，
/// 展示在状态卡上很难看。
class LinkTestException implements Exception {
  const LinkTestException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 保存一次运行的回调（`LinkTestStore.save` 签名与之一致）。
typedef RunSaver = Future<void> Function(LinkTestRun run);

/// 进度回调：结果列表 + 当前阶段文字（UI 据此刷新，内部已按 8 条节流）。
typedef LinkTestProgress = void Function(
    List<LinkTestResult> results, String stage);

// ---------------------------------------------------------------------------
// 端口池（逐个 bind 探活；全占用时返回不足数，不伪造成功）
// ---------------------------------------------------------------------------

/// 端口池：从 [kPortBase] 起，在 [kPortSpan] 跨度内逐个 `bind` 验证空闲。
///
/// 全占用时**绝不**兜底返回 20000（那会让第二个进程 bind 失败、整批报错），
/// 会导致 xray 启动必失败且原因不可读。这里返回 `(ports, missing)`，
/// 由调用方明确报「可用本地端口只剩 X 个」。
class PortPool {
  const PortPool({this.base = kPortBase, this.span = kPortSpan});

  final int base;
  final int span;

  /// 取 [n] 个空闲端口。返回的列表可能短于 [n]，差额即「不够」。
  Future<PortPick> pick(int n) async {
    if (n <= 0) return const PortPick(ports: <int>[], missing: 0);
    final ports = <int>[];
    for (var p = base; p < base + span && ports.length < n; p++) {
      if (await isFree(p)) ports.add(p);
    }
    return PortPick(ports: ports, missing: n - ports.length);
  }

  /// 单个端口是否空闲（bind 成功即空闲，立刻 close 释放）。
  ///
  /// bind 与真实监听之间存在竞态（R1），所以调用方在批量启动失败时要重挑一次。
  Future<bool> isFree(int port) async {
    ServerSocket? socket;
    try {
      socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      return true;
    } on Object {
      return false;
    } finally {
      try {
        await socket?.close();
      } on Object {
        // 关闭失败不影响判定
      }
    }
  }
}

/// [PortPool.pick] 的结果：拿到的端口 + 还差几个。
class PortPick {
  const PortPick({required this.ports, required this.missing});

  final List<int> ports;
  final int missing;

  bool get enough => missing == 0;
}

/// 把端口按**顺序**绑定到节点，返回 `[(节点, 端口)]`。
///
/// 为什么必须是纯函数：`ports[i] ↔ 节点 i` 是探测/结果/日志的唯一关联键。
/// 批量启动失败重挑端口时，如果就地改数组（只换端口不重建映射），结果会串到
/// 别人的行上 —— 真机上表现为「速度值看着合理但归属错了」，比失败更难发现。
List<(Vless, int)> bindPortsToNodes(List<Vless> nodes, List<int> ports) {
  if (nodes.length != ports.length) {
    throw ArgumentError(
      '端口数与节点数不一致：${nodes.length} 节点 / ${ports.length} 端口',
    );
  }
  return <(Vless, int)>[
    for (var i = 0; i < nodes.length; i++) (nodes[i], ports[i]),
  ];
}

// ---------------------------------------------------------------------------
// 编排器
// ---------------------------------------------------------------------------

/// 单节点探测的构造签名：`(测速地址, 延迟地址, 本机入站端口) -> 探测实例`。
///
/// 为什么把两个地址**都**透给工厂：延迟与速度是两个口径（见
/// [kDefaultLatencyUrl]），单测里注入的假探测必须能分别指向两个本地端点，
/// 否则「延迟阶段用了哪个端点」这件事在测试里不可见。
typedef LinkProbeFactory = LinkProbe Function(
  String speedUrl,
  String latencyUrl,
  int port,
);

/// 空地址 → 回落默认值。
///
/// 设置页允许把地址输入框清空（= 恢复默认），编排层就不能拿空串去探测；
/// 空地址在 `probeUri` 里会抛 `FormatException`，表现为「每条线路都地址非法」，
/// 用户完全看不出是自己删空了设置。
String _nonEmptyOr(String value, String fallback) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? fallback : trimmed;
}

/// 测速编排：端口 → 批量启动 → 延迟波 → AUTO 过滤 → 速度波 → 落盘 → 停进程。
///
/// 与 UI 完全解耦：依赖 [BatchXray]（可注入 fake）、[PortPool]、[LinkProbe] 工厂，
/// 因此全部分支都能在桌面单测覆盖（真机只负责验「xray 进程真的能起来」）。
class LinkTestRunner {
  LinkTestRunner({
    String speedUrl = kDefaultSpeedUrl,
    String latencyUrl = kDefaultLatencyUrl,
    required BatchXray xray,
    PortPool pool = const PortPool(),
    RunSaver? saver,
    LinkProbeFactory? probeFactory,
    void Function(String message)? onLog,
  })  : _speedUrl = _nonEmptyOr(speedUrl, kDefaultSpeedUrl),
        _latencyUrl = _nonEmptyOr(latencyUrl, kDefaultLatencyUrl),
        _xray = xray,
        _pool = pool,
        _saver = saver,
        _onLog = onLog,
        _probeFactory = probeFactory ??
            ((speed, latency, port) => LinkProbe(
                  speedUrl: speed,
                  latencyUrl: latency,
                  localPort: port,
                  // 生产路径开启预热：第一次请求含「建隧道 + CONNECT + 到目标
                  // TLS」约 4~5 个 RTT，用它当延迟会出现「v2rayN 80ms / 我们
                  // 1000ms」的不可比读数（两者量的不是同一段）。
                  warmUp: true,
                ));

  /// 速度阶段地址（大文件端点）。
  ///
  /// 非 final：设置页保存后由 [configureUrls] 在两轮之间换掉（见 AppState）。
  String _speedUrl;

  /// 延迟阶段地址（小端点）。
  String _latencyUrl;

  final BatchXray _xray;
  final PortPool _pool;
  final RunSaver? _saver;
  final LinkProbeFactory _probeFactory;

  /// 当前两个端点（只读，供日志/单测断言「这一轮打的是哪个地址」）。
  String get speedUrl => _speedUrl;
  String get latencyUrl => _latencyUrl;

  /// 换端点（设置页保存后调用）。
  ///
  /// 为什么允许运行中调用却**只改字段**：已经发出去的探测用的是构造时的地址，
  /// 改字段只影响下一轮。真正的「换地址」必须发生在两轮之间，否则同一轮的
  /// 延迟与速度会打到不同端点，读数不可比。
  ///
  /// 空串一律忽略：设置页允许用户把输入框清空，那是「恢复默认」的语义，
  /// 不能让 runner 拿着空地址去探测（每条线路都会报「地址非法」）。
  void configureUrls({String? speedUrl, String? latencyUrl}) {
    // 空串 / 纯空格的语义是**重置为默认**，不是「忽略」。
    //
    // 为什么不能只靠设置页归一化：用户「先设自定义 → 再清空 → 保存」时，
    // 若 runner 忽略空串，同一会话里仍会用那个自定义地址，只有重启读盘才回落
    // ——「清空」与「恢复默认」在用户看来是同一件事，行为却不一致就是 bug。
    // 正确性不能只押在 UI 层的一行 if 上。
    if (speedUrl != null) _speedUrl = _nonEmptyOr(speedUrl, kDefaultSpeedUrl);
    if (latencyUrl != null) {
      _latencyUrl = _nonEmptyOr(latencyUrl, kDefaultLatencyUrl);
    }
  }

  /// 诊断日志出口（可为 null）。
  ///
  /// 为什么编排层要打日志：延迟读数「看着不对」时，只看一个 TTFB 无法区分
  /// 「建连慢」「服务端压着不回响应头」「响应头到了 body 不来」，所以
  /// 每条探测都带一行分项计时（[ProbeTimings.summary]）。日志量 = 节点数，
  /// 不刷屏。
  ///
  /// 非 final 是为了 [ensureLogSink]：runner 常常是「先构造、后接线」的
  /// （AppState 构造期还不知道用哪个 sink），构造参数只能覆盖默认那条路。
  void Function(String message)? _onLog;

  /// 接上日志出口；**已有出口时不动**（构造参数显式传了 sink 就尊重它）。
  ///
  /// 为什么需要它：`AppState(runner: <注入的 runner>)` 这条路上，
  /// 构造参数里的 `onLog: pushLog` 根本不会执行，注入的 runner 会静默丢掉
  /// 全部测速日志 —— 表现是「测速日志面板一片空白」，排障时最需要它的时候没有。
  void ensureLogSink(void Function(String message) sink) {
    _onLog ??= sink;
  }

  final Semaphore _latGate = Semaphore(kLatencyParallel, name: 'latency');
  final Semaphore _speedGate = Semaphore(kSpeedParallel, name: 'speed');
  final List<LinkProbe> _live = <LinkProbe>[];

  bool _running = false;
  bool _cancelled = false;
  int _epoch = 0;
  int _sinceFlush = 0;

  /// 当前这一轮的完成 future（收尾结束才置 null）。
  ///
  /// 存在的唯一目的：让「取消后立刻再点开始」能**等上一轮收尾**而不是被判重入。
  /// 直接看 [_running] 不够 —— 取消是异步收尾的，用户点得比 unwind 快是常态。
  Future<void>? _activeRun;

  /// 开测前是否停掉了用户的单线路代理（K4）。
  ///
  /// T04 必须在为 true 时给出「测速已停止代理线路」提示，
  /// 文案常量用 `kProxyStoppedByTestMessage`。
  bool stoppedUserProxy = false;

  /// 是否已有一次运行在进行（与三阶段 `running` 互斥，UI 用它禁用按钮）。
  bool get running => _running;

  /// 本次运行是否被取消。
  bool get cancelled => _cancelled;

  /// 跑一次测速。
  ///
  /// 抛出 [LinkTestException]（可读文案）的三种情况，都属于「一个探测都没发」：
  /// 1. 上一次测速**没被取消**且还在进行（真重入）；
  /// 2. 没有可测条目；
  /// 3. 可用端口不足。
  ///
  /// 批量启动失败（含重挑端口一次后仍失败）**不抛**而是把每条结果标为 failed
  /// 并返回：用户需要看到「每条为什么失败」和 xray 尾部日志，抛异常会把这些信息
  /// 丢在 catch 里。这种情况下**不落盘**（不把一个 0 可用的 run 写进历史）。
  Future<LinkTestRun> run(
    List<String> links, {
    LinkTestMode mode = LinkTestMode.auto,
    LinkTestProgress? onProgress,
  }) async {
    // 上一轮还没收尾时有两种完全不同的情形：
    // - **没被取消**：这是真的重入 → 必须拒绝，否则两轮会共用端口池、结果表
    //   和 xray 批量进程；
    // - **已被取消**：只是探测还在 unwind（关 HttpClient / 停进程）。此时拒绝
    //   就正好命中老 bug「取消后立刻再点开始必然失败」，所以等它收尾再开新轮。
    final previous = _activeRun;
    if (previous != null) {
      if (!_cancelled) throw const LinkTestException('上一次测速还在进行');
      try {
        await previous;
      } on Object {
        // 上一轮的异常属于上一轮（结果早已通过 onProgress 交付），不能传染给
        // 这一轮：否则「取消后重测」会因为上一轮的报错再次失败。
      }
    }

    final done = Completer<void>();
    final mine = done.future;
    // compare-and-set：不能无条件赋值。
    //
    // `await previous` 期间，**另一个** run() 也可能等到了同一轮收尾并抢先登记
    // 新一轮；此时若直接 `_activeRun = mine`，就会把先到者的登记覆盖掉 ——
    // 后到者随后在 `_runOnce` 的 `_running` 兜底里抛错，`identical` 判真又把
    // 登记清成 null，于是**真正在跑的那一轮没人认识**：下一次「取消→立刻重测」
    // 就等不到它，直接命中「上一次测速还在进行」，Bug A 换个入口复发。
    if (_activeRun != null) throw const LinkTestException('上一次测速还在进行');
    _activeRun = mine;
    try {
      return await _runOnce(links, mode: mode, onProgress: onProgress);
    } finally {
      // identical 守卫是兜底：只有登记还是自己时才清，绝不误删别人的。
      if (identical(_activeRun, mine)) _activeRun = null;
      if (!done.isCompleted) done.complete();
    }
  }

  Future<LinkTestRun> _runOnce(
    List<String> links, {
    LinkTestMode mode = LinkTestMode.auto,
    LinkTestProgress? onProgress,
  }) async {
    if (_running) throw const LinkTestException('上一次测速还在进行');
    _running = true;
    _cancelled = false;
    _sinceFlush = 0;
    stoppedUserProxy = false;
    // ── Bug A 的根因就在这里 ────────────────────────────────────────────────
    // 两个闸门是本 runner 的**实例字段**，而 runner 在 AppState 里是 `late final`
    // 单例、跨轮复用；`cancel()` 会 `drain()` 它们，而 drain 是**永久**的
    // （此后每次 acquire 都抛 CancelledException，只有 reopen 能恢复）。
    // 旧代码全仓库没有一处 reopen，于是「取消一轮 → 再开一轮」时每个探测都在
    // acquire 处被判 cancelled，整批条目立刻变「已取消」（用户看到的现象）。
    //
    // 为什么必须**等上一轮收尾之后**再 reopen（顺序不能优化掉）：
    //
    // 许可数本身不会被抬高 —— `acquire()` 先 -1、`release()` 只是归还，
    // `acquire×6 → drain → reopen → release×6` 的终值仍然是 6（QA 用 12 次交错
    // 验证过 maxSeen == 6）。真正的风险是**在途探测还没收完就放新轮进来**：
    // 旧一轮那 6 路 socket 还在飞（关客户端要几个事件循环才真正结束），新一轮
    // 又会立刻派发 6 路，实际同时在飞的连接变成 12 —— 带宽被瓜分、读数失真、
    // 移动端还可能触发发热限流。`await previous` 的收益就是「旧连接收干净了
    // 才开新的」，别为了省几毫秒把它挪到 await 之前。
    _latGate.reopen();
    _speedGate.reopen();
    _runHint = '';
    final epoch = ++_epoch;
    final createdAt = DateTime.now().millisecondsSinceEpoch;

    // 1) 解析 + 逐条预检（D1：非法链接单独 failed，其余照测）
    final nodes = <Vless>[];
    final results = <LinkTestResult>[];
    final seen = <String>{};
    for (final raw in links) {
      final link = raw.trim();
      if (link.isEmpty) continue;
      final parsed = Vless.tryParse(link);
      if (parsed == null) {
        results.add(LinkTestResult(
          link: link,
          name: link.length > 40 ? '${link.substring(0, 40)}…' : link,
          host: '',
          port: 0,
          error: '链接无法解析（需 vless://uuid@host:port）',
          state: ProbeState.failed,
        ));
        continue;
      }
      final key = '${parsed.host}:${parsed.port}';
      if (!seen.add(key)) continue; // #13 按 link 去重（同 host:port 只测一次）
      nodes.add(parsed);
      results.add(LinkTestResult(
        link: link,
        name: parsed.name.isEmpty ? key : parsed.name,
        host: parsed.host,
        port: parsed.port,
      ));
    }

    if (nodes.isEmpty && results.isEmpty) {
      _running = false;
      throw const LinkTestException('先勾选至少一条线路');
    }
    _emit(results, '准备中', onProgress, force: true);
    // 把两个端点写进日志：延迟读数可疑时，第一件事就是确认「延迟到底探的是
    // 哪个地址」—— 混用大文件端点（含跳转）正是 Bug B 的根因。
    _onLog?.call('端点：延迟=$_latencyUrl · 速度=$_speedUrl');

    var started = false;
    try {
      // 2) 不再做「直连测速地址」的探活。
      //
      // 旧实现要求**手机自己**能直连 https://е.eu.org/300.zip，否则整批拒绝开测。
      // 但这条测速的流量本来就全走 VLESS 线路，国内网络直连多半不通 ——
      // 结果就是点了「开始测试」永远停在「准备中」。
      // 这里不做额外预筛：预检只判链接可解析，端口是否通由探测本身回答。

      if (nodes.isNotEmpty) {
        // 3) 端口池
        var picked = await _pool.pick(nodes.length);
        if (!picked.enough) {
          throw LinkTestException(
            '可用本地端口只剩 ${picked.ports.length} 个，请减少勾选条数',
          );
        }

        // 4) 批量启动（含 1 次「重挑端口」重试，映射用纯函数重建）
        //
        // K4 记账必须在调用**之前**：真实 `XrayProc.startBatch` 第一行就是
        // `await stop()`（串行互斥），所以只要 `wasLine` 为真，代理在此刻就已经
        // 死了 —— 无论后面成功还是失败。等到成功分支再置位，就会出现
        // 「代理被杀但 UI 不提示」，正是 K4 明令禁止的。
        final wasLine = _xray.mode == XrayMode.line;
        if (wasLine) stoppedUserProxy = true;
        var bound = bindPortsToNodes(nodes, picked.ports);
        var error = await _xray.startBatch(bound);
        if (error != null) {
          // R1：端口 bind 探测与真实监听之间有竞态，重挑一次
          picked = await _pool.pick(nodes.length);
          if (picked.enough) {
            bound = bindPortsToNodes(nodes, picked.ports);
            error = await _xray.startBatch(bound);
          }
        }
        if (error != null) {
          // K5：绝不带着未就绪端口进探测 —— 全部标失败、不落盘
          _failAll(results, '批量启动失败：$error');
          _emit(results, '启动失败', onProgress, force: true);
          return LinkTestRun(
            id: '$createdAt',
            createdAt: createdAt,
            mode: mode,
            results: List<LinkTestResult>.unmodifiable(results),
          );
        }
        started = true;

        // 5) 延迟阶段（6 路）
        //    speed 模式跳过：速度探测的 TTFB 本身就兼作延迟，
        //    多测一遍既慢又会覆盖掉真实的首字节时间。
        if (mode != LinkTestMode.speed) {
          await _runLatencyStage(
            results: results,
            bound: bound,
            epoch: epoch,
            onProgress: onProgress,
          );
        }

        if (!_cancelled && mode != LinkTestMode.latency) {
          // 6) 速度阶段（2 路）：auto 只测「有响应」的；speed 全测
          final candidates = <(Vless, int)>[];
          for (final entry in bound) {
            final result = results[_indexOfResult(results, entry.$1)];
            if (result.state == ProbeState.cancelled) continue;
            if (result.error != null) continue; // 死链不进速度阶段（省 3s 空转）
            final wantSpeed = mode == LinkTestMode.speed ||
                (mode == LinkTestMode.auto && result.latencyKnown);
            if (wantSpeed) candidates.add(entry);
          }
          if (candidates.isNotEmpty) {
            _emit(results, '速度探测', onProgress, force: true);
            await _stage(
              results: results,
              bound: candidates,
              gate: _speedGate,
              speedStage: true,
              epoch: epoch,
              onProgress: onProgress,
            );
          }
        }
      }

      // 7) 收尾：终态整理 → 落盘 → 停进程
      _finalize(results);
      final run = LinkTestRun(
        id: '$createdAt',
        createdAt: createdAt,
        mode: mode,
        results: List<LinkTestResult>.unmodifiable(results),
      );
      final finishedLabel = _cancelled ? '已取消' : '完成';
      _emit(
        results,
        _runHint.isEmpty ? finishedLabel : '$finishedLabel · $_runHint',
        onProgress,
        force: true,
      );
      await _save(run);
      return run;
    } finally {
      if (started) {
        // 无论成功/失败/取消都停进程：K4「测速不得留一个批量代理在后面」
        await _xray.stop();
      }
      _running = false;
    }
  }

  /// 取消：置位 → 关闭在途 HttpClient（在途 `await for` 立即结束）→ 杀进程。
  ///
  /// 三段缺一不可（取消链路三段）：只置位队列会继续派发；只关客户端进程还在跑、
  /// 端口不释放；只杀进程则探测端会一直等到 12s 超时才收尾。
  ///
  /// 注意这里**只 drain、不 reopen**：取消后的闸门必须保持关闭，才能挡住本轮
  /// 排队者。恢复到可用状态是下一轮 [_runOnce] 的责任（这就是 Bug A 的修法），
  /// 不要在 cancel 里顺手 reopen —— 那会让排队者在取消后照样发出探测。
  Future<void> cancel() async {
    if (!_running) return;
    _cancelled = true;
    _latGate.drain();
    _speedGate.drain();
    for (final probe in List<LinkProbe>.of(_live)) {
      probe.cancel();
    }
    await _xray.stop();
  }

  // --- 内部 -----------------------------------------------------------------

  /// 延迟阶段：按候选端点链跑，**整批**一条都没拿到延迟、且失败**全部**是
  /// 建连类（非超时）时，才换端点重跑。
  ///
  /// 判定为什么必须是「整批」而不是「单条」：
  /// - 端点不可达 → 整批同样失败（每条都连不上那个域名）→ 换端点有意义；
  /// - 节点真死 → 只要还有一条拿到延迟，就说明端点本身是通的，换端点只是
  ///   把死链重新跑一遍，白等 N×[kLatencyTimeout]。
  /// 这条区分正是「端点坏」与「线路全挂」在行为上唯一可靠的分界。
  ///
  /// 为什么**超时不算「端点不可达」**（第二条分界，见 [_runLatencyStage] 内的
  /// `timedOutCount` 分支）：
  /// - [kLatencyTimeout] 只有 5s，比 [kConnectTimeout]（8s）还短；
  /// - 跨境 RTT 300ms+ 的线路，首字节落在 5~12s 是常态，这类节点「慢但活着」；
  /// - 一整批全是超时，几乎只能是「线路慢」——换端点不会更快，只是再等一轮，
  ///   而且整批会被判失败、本轮数据全丢。
  /// 所以只有建连类失败（连接被拒 / TLS 握手失败）才换端点。
  Future<void> _runLatencyStage({
    required List<LinkTestResult> results,
    required List<(Vless, int)> bound,
    required int epoch,
    required LinkTestProgress? onProgress,
  }) async {
    final candidates = latencyCandidates();
    final maxAttempts = candidates.length < kLatencyMaxAttempts
        ? candidates.length
        : kLatencyMaxAttempts;

    // 本轮是否出现过超时（用于结束时的可执行提示，见方法末尾）。
    var sawTimeout = false;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (!_isCurrent(epoch)) return;

      // 已经拿到延迟的条目不参与重跑（正常情况下走不到：只要有 1 条成功就
      // 不切换，见下面的 anyKnown 判断）。
      final pending = <(Vless, int)>[
        for (final entry in bound)
          if (!results[_indexOfResult(results, entry.$1)].latencyKnown) entry,
      ];
      if (pending.isEmpty) return;

      // 阶段文案要把「第几次尝试 / 共几次 / 还要等多久」说清楚：
      // 端点全挂时这段会连续停 10~15s，只写「延迟探测」用户会以为卡死。
      //
      // 但**首轮（attempt == 0）不许带「端点 1/3」**：健康网络下第一次探测
      // 就写「端点 1/3」，用户会以为自己已经在看第 1 次重试 / 后面还有两次要等，
      // 而实际上 99% 的情况这一轮就结束了。只有真的开始重试（attempt >= 1）
      // 才值得报进度。
      // 死线按轮次分：**首轮用 [kConnectTimeout]（8s），重试轮用
      // [kLatencyTimeout]（5s）**。
      //
      // 为什么首轮要更长：5s 死线比 8s 建连超时还短，看门狗先开枪，于是
      // 「对方完全不可达」在客户端的主信号被记成「超时」——而超时既可能是
      // 端点被墙，也可能是节点慢，两者分不开，候选链就等于白加。
      // 首轮给足 8s，让「连接被拒/DNS 失败」有机会以**建连类**失败先暴露
      // （毫秒级），同时给首字节 5~12s 的慢节点留出数机会；重试轮求快，用 5s。
      final attemptTimeout = attempt == 0 ? kConnectTimeout : kLatencyTimeout;

      final label = maxAttempts == 1 || attempt == 0
          ? '延迟探测'
          : '延迟探测（端点 ${attempt + 1}/$maxAttempts，'
              '约再 ${attemptTimeout.inSeconds} 秒）';
      _emit(results, label, onProgress, force: true);

      await _stage(
        results: results,
        bound: pending,
        gate: _latGate, // 重跑必须复用同一个闸门，否则切端点那一刻并发翻倍
        speedStage: false,
        epoch: epoch,
        onProgress: onProgress,
        latencyUrl: candidates[attempt],
        latencyTimeout: attemptTimeout,
      );

      if (!_isCurrent(epoch)) return;
      if (_anyLatencyKnown(results)) break; // 端点没问题，失败的是真死链

      // 本次尝试**实际派发过**的条目里，失败了多少条、其中多少条是超时。
      //
      // 排除两类，它们不能参与统计：
      // - 预检失败（[LinkTestResult.host] 为空）：**根本没派发**，它失败是因为
      //   链接非法，跟端点毫无关系。把它算进来会得出「整批失败」的假结论；
      // - 已取消：用户主动中断，不是任何一方的故障。
      //
      // 判据读的是 [LinkTestResult.timedOut] 标志位，**不是** [LinkTestResult.error]
      // 的文案 —— 文案随时会改（见 kProbeTimeout 的注释），拿字符串比较的话，
      // 改一次文案就会静默把「不切换」变回「切换」，这种退化在测试里也看不出来。
      var attemptedCount = 0;
      var failedCount = 0;
      var timedOutCount = 0;
      var connectLikeCount = 0;
      for (final entry in pending) {
        final result = results[_indexOfResult(results, entry.$1)];
        if (result.host.isEmpty) continue; // 预检失败：没派发
        if (result.state == ProbeState.cancelled) continue; // 没跑完
        attemptedCount++;
        if (result.error == null) continue; // 没失败（含「有结果但没读数」）
        failedCount++;
        if (result.timedOut) timedOutCount++;
        if (result.failureKind.isConnectLike) connectLikeCount++;
      }

      // ── 这里的判定是本次修复的核心 ───────────────────────────────────────
      // kLatencyTimeout 是 5s，比建连超时（8s）还短，所以**慢但活着的节点**
      // （首字节 5~12s）必然踩死线。超时只能证明「这么久没拿到首字节」，
      // 它**不能**证明端点不可达 —— 换端点再跑一遍，慢的还是慢，只是又白等 5s，
      // 而且把本轮本来能测出的数据全丢（整批判失败）。
      // 只有当失败**全部**是建连类（连接被拒 / TLS 握手失败 / DNS 失败）时，
      // 「换个端点」才有意义：那是端点或线路真的不可达。
      // 超时：**首轮允许切一次，重试轮不再切**。
      //
      // 不能一刀切「超时永不切换」：真机上「对方完全不可达」（SYN 黑洞/被墙）
      // 的主信号可能正是超时，那样候选链永远不触发，fallback 变成空壳。
      // 也不能无限切：第二个端点同样超时，几乎只能是线路慢，再切只是白等。
      // 所以取中间值 —— 最多为「分辨端点坏还是线路慢」付一次 attemptTimeout。
      if (timedOutCount > 0) {
        sawTimeout = true;
        // 「超时 + 建连类」混合时不切：超时已经证明至少有一部分链路是活的，
        // 换端点救不了；只有**清一色超时**才值得再试一个端点（区分端点坏/线路慢）。
        if (timedOutCount != failedCount) {
          _onLog?.call(
            '延迟阶段 $failedCount 条全部未成功，原因是混合的'
            '（$timedOutCount 条超时 + ${failedCount - timedOutCount} 条其它），'
            '不切换端点',
          );
          break;
        }
        if (attempt == 0 && attempt + 1 < maxAttempts) {
          _onLog?.call(
            '首轮 $failedCount 条全部未成功（其中 $timedOutCount 条超时，'
            '${attemptTimeout.inSeconds}s 内未收到首字节），'
            '端点不可达与线路慢无法区分，试下一个候选',
          );
          // 继续往下走到「清失败 → 切端点」。
        } else {
          _onLog?.call(
            '端点 ${attempt + 1}/$maxAttempts 同样全部超时'
            '（$timedOutCount 条），判为线路慢，停止切换端点',
          );
          break;
        }
      }

      // 其次：失败原因必须**清一色**是建连类（连接被拒 / TLS 握手失败 / DNS 失败）。
      // 出现 HTTP 4xx-5xx、参数错误、数据为空这些原因时，说明链路是通的、
      // 只是对方不配合 —— 换端点救不了，只会白等。判定只读 [ProbeFailureKind]。
      final connectLikeOnly =
          attemptedCount > 0 && connectLikeCount == attemptedCount;
      if (timedOutCount == 0 && !connectLikeOnly) {
        _onLog?.call(
          '延迟阶段 $failedCount 条全部未成功，失败原因不是清一色的建连类'
          '（$connectLikeCount/$attemptedCount 条为连接失败/TLS 握手失败），'
          '不足以断定端点不可达，不切换端点',
        );
        break;
      }

      if (attempt + 1 >= maxAttempts) break; // 候选用完了

      // 换端点前把**因延迟探测失败**的结果清回未测：
      // ① 不清的话 `_stage` 里 `if (results[index].error != null) continue;`
      //    会把它们全部跳过，看起来像「什么都没发生」；
      // ② 但预检失败（链接无法解析）**绝不能清** —— 那是不可恢复的，
      //    清掉后它会以「端点不可达」重新报错，排障方向全错。
      _clearLatencyFailures(results);
      _onLog?.call(
        '延迟端点 ${candidates[attempt]} 拿不到延迟'
        '（${bound.length} 条全部失败），换下一个候选：${candidates[attempt + 1]}',
      );
    }

    // 整轮结束仍「一条都没测出」且有超时：把可执行建议放到**阶段文案**上。
    // 只写日志不够 —— 用户不一定翻日志，而这个结论直接决定他下一步动作。
    if (sawTimeout && !_anyLatencyKnown(results) && _isCurrent(epoch)) {
      const hint = '延迟全部超时；若节点本身可用，请更换「延迟测试地址」';
      _runHint = hint;
      _emit(results, hint, onProgress, force: true);
    }
  }

  /// 延迟阶段的候选端点链（按字符串去重、保序）。
  ///
  /// 顺序：设置里的首选 → 内置候选 → 速度端点（最后的兜底）。
  /// 为什么把速度端点放末尾：它是已知可达的大文件端点，其余候选都不可达时
  /// 它至少能证明「线路能通」，读数偏脏（含服务端缓冲/跳转），但比整批失败
  /// 更有诊断价值。
  ///
  /// 去重是必须的：用户完全可能把首选填成和内置候选一模一样的值。
  List<String> latencyCandidates() {
    final out = <String>[];
    void add(String value) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return;
      if (out.contains(trimmed)) return;
      out.add(trimmed);
    }

    add(_latencyUrl);
    for (final url in kLatencyFallbackUrls) {
      add(url);
    }
    add(_speedUrl);
    return out;
  }

  /// 整批里是否已经有任何一条拿到延迟。
  bool _anyLatencyKnown(List<LinkTestResult> results) =>
      results.any((r) => r.latencyKnown);

  /// 把「因延迟探测而失败」的条目清回未测（不碰预检失败）。
  ///
  /// 为什么不用 `copyWith`：它的所有参数都是 `??`，**无法把 error 清回 null**
  /// （见 LinkTestResult.copyWith 的已知限制）；这里必须整条重建。
  void _clearLatencyFailures(List<LinkTestResult> results) {
    for (var i = 0; i < results.length; i++) {
      final result = results[i];
      if (result.host.isEmpty) continue; // 预检失败（非法链接）不可恢复，保留
      if (result.state == ProbeState.cancelled) continue;
      if (result.error == null) continue;
      results[i] = LinkTestResult(
        link: result.link,
        name: result.name,
        host: result.host,
        port: result.port,
      );
    }
  }

  /// 跑一个阶段：所有目标并发派发，受 [gate] 限流。
  Future<void> _stage({
    required List<LinkTestResult> results,
    required List<(Vless, int)> bound,
    required Semaphore gate,
    required bool speedStage,
    required int epoch,
    required LinkTestProgress? onProgress,
    String? latencyUrl,
    Duration? latencyTimeout,
  }) async {
    final tasks = <Future<void>>[];
    for (final (node, port) in bound) {
      final index = _indexOfResult(results, node);
      if (results[index].error != null) continue; // 预检/上阶段已失败
      tasks.add(_probeOne(
        index: index,
        port: port,
        gate: gate,
        speedStage: speedStage,
        results: results,
        epoch: epoch,
        onProgress: onProgress,
        latencyUrl: latencyUrl,
        latencyTimeout: latencyTimeout,
      ));
    }
    await Future.wait(tasks);
  }

  Future<void> _probeOne({
    required int index,
    required int port,
    required Semaphore gate,
    required bool speedStage,
    required List<LinkTestResult> results,
    required int epoch,
    required LinkTestProgress? onProgress,
    String? latencyUrl,
    Duration? latencyTimeout,
  }) async {
    if (!_isCurrent(epoch)) return;
    try {
      await gate.acquire();
    } on CancelledException {
      _mark(results, index, ProbeState.cancelled);
      _flush(results, onProgress);
      return;
    }

    // 双保险：`drain()` 已经会让排队者以 CancelledException 失败，但那是单点保护——
    // 一旦有人重构掉 drain（或改成只在 cancel 时置标志），排队者就会在取消后照样
    // 发探测。这里拿到许可后**再确认一次**是否还是当前这一轮。
    if (!_isCurrent(epoch)) {
      _mark(results, index, ProbeState.cancelled);
      gate.release();
      _flush(results, onProgress);
      return;
    }

    // 延迟阶段允许按候选链临时换端点（[latencyUrl]）与死线（[latencyTimeout]）；
    // 速度阶段永远用设置里那个端点与 kSpeedTimeout。
    final probe = _probeFactory(_speedUrl, latencyUrl ?? _latencyUrl, port);
    if (!speedStage && latencyTimeout != null) {
      probe.latencyTimeout = latencyTimeout;
    }
    _live.add(probe);
    _mark(results, index, ProbeState.running);
    try {
      final outcome = speedStage ? await probe.speed() : await probe.latency();
      // 过期回调直接丢弃（R6：取消/重测之后到达的结果不能覆盖新状态）
      if (!_isCurrent(epoch)) return;
      _applyOutcome(results, index, outcome, speedStage: speedStage);
      _logOutcome(results[index], outcome, speedStage: speedStage);
    } on Object catch (e) {
      if (_isCurrent(epoch)) {
        _setResult(
          results,
          index,
          results[index].copyWith(
            error: humanizeProbeError(e),
            state: ProbeState.failed,
            // 探测层把异常抛上来（而不是包成 outcome）时，类别同样要带上：
            // 延迟阶段靠它判断「这个失败是不是建连类」，别让这里退回 other。
            failureKind: classifyProbeFailure(e),
          ),
        );
      }
    } finally {
      _live.remove(probe);
      probe.cancel();
      gate.release();
      _flush(results, onProgress);
    }
  }

  void _applyOutcome(
    List<LinkTestResult> results,
    int index,
    LinkProbeOutcome outcome, {
    required bool speedStage,
  }) {
    final before = results[index];
    if (outcome.cancelled) {
      _setResult(results, index, before.copyWith(state: ProbeState.cancelled));
      return;
    }
    if (outcome.error != null) {
      _setResult(
        results,
        index,
        before.copyWith(
          // 速度阶段失败时保留延迟阶段的 TTFB（AUTO 的诊断价值就在这）
          latencyMs: before.latencyKnown ? before.latencyMs : outcome.ttfbMs,
          elapsedMs: outcome.elapsedMs,
          error: outcome.error,
          state: ProbeState.failed,
          // 失败类别必须带到结果层：延迟阶段靠它区分「线路慢」与「端点坏」。
          failureKind: outcome.failureKind,
        ),
      );
      return;
    }
    // 延迟阶段的 TTFB 已经是「可比口径」（小端点、不跟随跳转），**不许**被
    // 速度阶段的 TTFB 覆盖：速度阶段读的是大文件端点，还跟着跳转，
    // 它的首字节天然更大（Bug B 的第二条根因 —— AUTO 是默认模式，如果没有
    // 这一行，延迟阶段刚测准的数会被当场换成「含跳转 + 服务端缓冲」的脏数）。
    // 只有「本行还没有延迟」（speed-only 模式）时才让速度阶段兼作延迟。
    final keepLatency = speedStage && before.latencyKnown;
    _setResult(
      results,
      index,
      before.copyWith(
        latencyMs: keepLatency
            ? before.latencyMs
            : (outcome.ttfbMs >= 0 ? outcome.ttfbMs : before.latencyMs),
        speedMib: outcome.speedMib,
        elapsedMs: outcome.elapsedMs,
        error: null,
        state: ProbeState.done,
        // 成功必须把类别复位：否则「上一轮超时、本轮成功」会留下
        // `timedOut == true && error == null` 这种自相矛盾的行。
        // （`failureKind` 是 none 时 `timedOut` getter 自然为 false。）
        failureKind: outcome.failureKind,
      ),
    );
  }

  /// 打一条分项计时日志（[LinkProbeOutcome.timings] 的唯一消费者）。
  ///
  /// 只在这里拼字符串：探测层不 import 任何「日志」概念，保持可纯 Dart 单测。
  void _logOutcome(
    LinkTestResult result,
    LinkProbeOutcome outcome, {
    required bool speedStage,
  }) {
    final log = _onLog;
    if (log == null) return;
    final stage = speedStage ? '速度' : '延迟';
    final timings = outcome.timings;
    final parts = <String>[
      '$stage ${result.name}',
      'ttfb=${result.latencyMs}ms',
      if (speedStage && result.speedMib != null)
        '速度=${result.speedMib!.toStringAsFixed(2)}MiB/s',
      '耗时=${outcome.elapsedMs}ms',
      if (timings != null) timings.summary,
      if (outcome.error != null) '错误=${outcome.error}',
    ];
    log('· ${parts.join(' · ')}');
  }

  /// 终态整理：还没到终态的（未派发/被取消）统一标 cancelled。
  void _finalize(List<LinkTestResult> results) {
    for (var i = 0; i < results.length; i++) {
      final state = results[i].state;
      if (state == ProbeState.pending || state == ProbeState.running) {
        _setResult(
            results, i, results[i].copyWith(state: ProbeState.cancelled));
      }
    }
  }

  void _failAll(List<LinkTestResult> results, String error) {
    for (var i = 0; i < results.length; i++) {
      if (results[i].state == ProbeState.failed) continue; // 预检失败原因更具体，保留
      _setResult(
        results,
        i,
        results[i].copyWith(error: error, state: ProbeState.failed),
      );
    }
  }

  Future<void> _save(LinkTestRun run) async {
    final saver = _saver;
    if (saver == null) return;
    try {
      await saver(run);
    } on Object {
      // 写盘失败不阻断结果展示（T03 验收 5）
    }
  }

  bool _isCurrent(int epoch) => epoch == _epoch && !_cancelled;

  /// 结果列表里该节点的下标。节点按顺序入列，用 host:port 反查（不依赖下标算术，
  /// 因为预检失败项会占用前面的位置）。
  int _indexOfResult(List<LinkTestResult> results, Vless node) {
    final key = '${node.host}:${node.port}';
    for (var i = 0; i < results.length; i++) {
      if (results[i].key == key) return i;
    }
    throw StateError('结果里找不到节点 $key');
  }

  void _setResult(
      List<LinkTestResult> results, int index, LinkTestResult value) {
    results[index] = value;
  }

  void _mark(List<LinkTestResult> results, int index, ProbeState state) {
    _setResult(results, index, results[index].copyWith(state: state));
  }

  /// 每 [kResultFlushEvery] 条 flush 一次；[force] 用于阶段切换/收尾。
  void _flush(List<LinkTestResult> results, LinkTestProgress? onProgress) {
    _sinceFlush++;
    if (_sinceFlush < kResultFlushEvery) return;
    _sinceFlush = 0;
    onProgress?.call(_snapshot(results), _stageLabel);
  }

  String _stageLabel = '';

  /// 收尾时要带给用户的**可执行提示**（空 = 没有）。
  ///
  /// 为什么不能只 `_emit` 一次就完：`_runOnce` 末尾会再 emit「完成」把阶段文案
  /// 覆盖掉，用户看到的最终状态里就丢了这句话 —— 而这句话恰恰是失败时刻唯一
  /// 有行动价值的信息。
  String _runHint = '';

  void _emit(
    List<LinkTestResult> results,
    String stage,
    LinkTestProgress? onProgress, {
    bool force = false,
  }) {
    _stageLabel = stage;
    _sinceFlush = 0;
    if (force) onProgress?.call(_snapshot(results), stage);
  }

  List<LinkTestResult> _snapshot(List<LinkTestResult> results) =>
      List<LinkTestResult>.unmodifiable(results);
}
