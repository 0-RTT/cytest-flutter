import 'dart:async';
import 'dart:io';

import '../core/idna.dart';
import '../core/semaphore.dart';
import 'link_probe.dart';
import 'vless.dart';
import 'xray.dart';

// ---------------------------------------------------------------------------
// 模型（字段语义与 Kotlin LinkTestModels / LinkTestMode 一一对应）
// ---------------------------------------------------------------------------

/// 测速模式。出处：Kotlin `LinkTestMode`。
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

/// 模式的界面文案（UI 只取值，不自己造句，避免两处文案漂移）。
extension LinkTestModeLabel on LinkTestMode {
  String get label => switch (this) {
        LinkTestMode.latency => '只测延迟',
        LinkTestMode.speed => '只测速度',
        LinkTestMode.auto => '自动（先延迟后速度）',
      };
}

/// 单条结果。
///
/// 与 Kotlin `LinkTestResult` 字段一一对应，**只有 [speedMib] 改成可空**（差异 D2）：
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

  /// 结果 key：`host:port`（照搬 Kotlin `withResult` 的 key 口径）。
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
      );

  @override
  String toString() =>
      'LinkTestResult($name, ${state.name}, ttfb=$latencyMs, speed=$speedMib)';
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

  /// `createdAt` 的毫秒串（照搬 Kotlin 的 id 口径）。
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
// 端口池（照搬 Kotlin LinkTestController.pick + 修掉「占用时返回 20000」的假成功）
// ---------------------------------------------------------------------------

/// 端口池：从 [kPortBase] 起，在 [kPortSpan] 跨度内逐个 `bind` 验证空闲。
///
/// 差异 D3：Kotlin 的 `freePort()` 在全占用时**兜底返回 20000**（假成功），
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

/// 测速编排：预检 → 端口 → 批量启动 → 延迟波 → AUTO 过滤 → 速度波 → 落盘 → 停进程。
///
/// 与 UI 完全解耦：依赖 [BatchXray]（可注入 fake）、[PortPool]、[LinkProbe] 工厂，
/// 因此全部分支都能在桌面单测覆盖（真机只负责验「xray 进程真的能起来」）。
class LinkTestRunner {
  LinkTestRunner({
    String speedUrl = kDefaultSpeedUrl,
    required BatchXray xray,
    PortPool pool = const PortPool(),
    RunSaver? saver,
    LinkProbe Function(String speedUrl, int port)? probeFactory,
    Future<String?> Function()? liveness,
  })  : _speedUrl = speedUrl,
        _xray = xray,
        _pool = pool,
        _saver = saver,
        _probeFactory = probeFactory ??
            ((url, port) => LinkProbe(speedUrl: url, localPort: port)),
        _liveness = liveness;

  final String _speedUrl;
  final BatchXray _xray;
  final PortPool _pool;
  final RunSaver? _saver;
  final LinkProbe Function(String speedUrl, int port) _probeFactory;
  final Future<String?> Function()? _liveness;

  final Semaphore _latGate = Semaphore(kLatencyParallel, name: 'latency');
  final Semaphore _speedGate = Semaphore(kSpeedParallel, name: 'speed');
  final List<LinkProbe> _live = <LinkProbe>[];

  bool _running = false;
  bool _cancelled = false;
  int _epoch = 0;
  int _sinceFlush = 0;

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
  /// 1. 没有可测条目；
  /// 2. K3 测速源探活失败（**不动任何已有结果**，不写历史）；
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
    if (_running) throw const LinkTestException('上一次测速还在进行');
    _running = true;
    _cancelled = false;
    _sinceFlush = 0;
    stoppedUserProxy = false;
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

    var started = false;
    try {
      // 2) K3 探活：失败只阻止开测，不碰已有结果、不写历史
      final liveError = await _checkSource();
      if (liveError != null) {
        throw LinkTestException(
          '测速源不可用（$liveError），已取消本次测试（不影响已有结果）',
        );
      }

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
        //    speed 模式跳过：速度探测的 TTFB 本身就兼作延迟（照搬 Kotlin），
        //    多测一遍既慢又会覆盖掉真实的首字节时间。
        if (mode != LinkTestMode.speed) {
          _emit(results, '延迟探测', onProgress, force: true);
          await _stage(
            results: results,
            bound: bound,
            gate: _latGate,
            speedStage: false,
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
      _emit(results, _cancelled ? '已取消' : '完成', onProgress, force: true);
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
  /// 三段缺一不可（设计 §2.3）：只置位队列会继续派发；只关客户端进程还在跑、
  /// 端口不释放；只杀进程则探测端会一直等到 12s 超时才收尾。
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

  /// 跑一个阶段：所有目标并发派发，受 [gate] 限流。
  Future<void> _stage({
    required List<LinkTestResult> results,
    required List<(Vless, int)> bound,
    required Semaphore gate,
    required bool speedStage,
    required int epoch,
    required LinkTestProgress? onProgress,
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

    final probe = _probeFactory(_speedUrl, port);
    _live.add(probe);
    _mark(results, index, ProbeState.running);
    try {
      final outcome = speedStage ? await probe.speed() : await probe.latency();
      // 过期回调直接丢弃（R6：取消/重测之后到达的结果不能覆盖新状态）
      if (!_isCurrent(epoch)) return;
      _applyOutcome(results, index, outcome, speedStage: speedStage);
    } on Object catch (e) {
      if (_isCurrent(epoch)) {
        _setResult(
          results,
          index,
          results[index].copyWith(
            error: humanizeProbeError(e),
            state: ProbeState.failed,
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
        ),
      );
      return;
    }
    _setResult(
      results,
      index,
      before.copyWith(
        latencyMs: outcome.ttfbMs >= 0 ? outcome.ttfbMs : before.latencyMs,
        speedMib: outcome.speedMib,
        elapsedMs: outcome.elapsedMs,
        error: null,
        state: ProbeState.done,
      ),
    );
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

  /// K3：开测前直连测速地址探活（1 次、8s 超时）。null = 可用，字符串 = 失败原因。
  Future<String?> _checkSource() async {
    final injected = _liveness;
    if (injected != null) return injected();
    HttpClient? client;
    try {
      final uri = probeUri(_speedUrl); // IDN 不支持会在这里抛，直接拒绝开测
      client = HttpClient()..connectionTimeout = kConnectTimeout;
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(kConnectTimeout);
      await response.drain<void>().catchError((Object _) {});
      return null;
    } on UnsupportedIdnException catch (e) {
      return '测速地址含不支持的字符：${e.message}';
    } on Object catch (e) {
      return humanizeProbeError(e);
    } finally {
      client?.close(force: true);
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
