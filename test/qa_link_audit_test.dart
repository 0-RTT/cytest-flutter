// QA 独立审计（严过关）：对「取消后再测必失败」「延迟读数远大于 v2rayN」两个修复
// 做**证伪式**验证。
//
// 与 `test/link_rerun_test.dart`、`test/link_probe_test.dart` 的关系：那两个文件由
// 工程师编写，本文件刻意**不复用**它们的断言与辅助类，用另一套口径重测同一批行为，
// 避免「测试跟着实现一起错」。本文件覆盖工程师用例没覆盖的四个缺口：
//
// 1. 闸门许可是否会被「上一轮迟到的 release」抬高（并发上限被静默突破）；
// 2. 取消的四种边界时刻（延迟段中/速度段中/未派发/取消后不 await 立即重测）；
// 3. 语义不许退化（null ≠ 0.0、cancelled ≠ failed、真重入仍须抛错、速度段仍跟跳转）；
// 4. 接线完整性（onLog → AppState.logs → LogPanel；两个端点真正分流到两个方法）。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/core/semaphore.dart';
import 'package:cytest/data/link_probe.dart';
import 'package:cytest/data/link_test.dart';
import 'package:cytest/data/vless.dart';
import 'package:cytest/data/xray.dart';
import 'package:cytest/state/app_state.dart';

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

const String _latencyUrl = 'http://audit.test/generate_204';
const String _speedUrl = 'http://audit.test/300.zip';

String _link(String host, int port) =>
    'vless://uuid-$port@$host:$port?type=ws&security=tls&sni=$host&path=%2Fws';

/// 可控批量启动器；[startGate] 非空时 `startBatch` 会挂住，
/// 用来制造「全部条目还没派发就取消」这个时刻。
class _FakeXray implements BatchXray {
  _FakeXray({this.startGate});

  final Completer<void>? startGate;
  int startCalls = 0;
  int stopCalls = 0;

  @override
  XrayMode mode = XrayMode.none;

  @override
  Future<String?> startBatch(List<(Vless, int)> nodes) async {
    startCalls++;
    await stop(); // 与真实 XrayProc.startBatch 一致：第一行就 stop()
    final gate = startGate;
    if (gate != null) await gate.future;
    mode = XrayMode.batch;
    return null;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    mode = XrayMode.none;
  }
}

/// 固定端口池（端口只在单测里当「编号」用，不会真去 bind）。
class _FixedPool extends PortPool {
  _FixedPool(this._ports);

  final List<int> _ports;

  @override
  Future<PortPick> pick(int n) async {
    final ports = _ports.take(n).toList(growable: false);
    return PortPick(ports: ports, missing: n - ports.length);
  }
}

/// 完全受控的探测：延迟/速度由外部决定何时、以什么结果返回。
///
/// 用**子类化**而不是 fake HTTP 服务，是为了把「取消发生在哪一段」变成
/// 确定性的断言（真实 socket 的时序在 CI 上会抖）。
class _ScriptedProbe extends LinkProbe {
  _ScriptedProbe({
    required super.localPort,
    this.onLatency,
    this.onSpeed,
  }) : super(speedUrl: _speedUrl, latencyUrl: _latencyUrl);

  final Future<LinkProbeOutcome> Function(_ScriptedProbe probe)? onLatency;
  final Future<LinkProbeOutcome> Function(_ScriptedProbe probe)? onSpeed;

  int latencyCalls = 0;
  int speedCalls = 0;

  final Completer<void> _cancelSignal = Completer<void>();

  /// 本探测被 `cancel()` 的时刻（用来做「挂到取消为止」的挂件）。
  Future<void> get cancelSignal => _cancelSignal.future;

  @override
  Future<LinkProbeOutcome> latency() {
    latencyCalls++;
    return (onLatency ?? _defaultLatency)(this);
  }

  @override
  Future<LinkProbeOutcome> speed() {
    speedCalls++;
    return (onSpeed ?? _defaultSpeed)(this);
  }

  @override
  void cancel() {
    super.cancel();
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
  }
}

Future<LinkProbeOutcome> _defaultLatency(_ScriptedProbe _) async =>
    const LinkProbeOutcome(ttfbMs: 10, elapsedMs: 10);

Future<LinkProbeOutcome> _defaultSpeed(_ScriptedProbe _) async =>
    const LinkProbeOutcome(ttfbMs: 20, speedMib: 1.5, elapsedMs: 200);

/// 一直挂到被取消为止，然后如实报 cancelled。
Future<LinkProbeOutcome> _hangUntilCancelled(_ScriptedProbe probe) async {
  await probe.cancelSignal;
  return LinkProbeOutcome.cancelledAt(1);
}

/// 记录 `probeFactory` 收到的两个地址（验证编排层的「端点分流」）。
class _ProbeSink {
  final List<String> speedUrls = <String>[];
  final List<String> latencyUrls = <String>[];
  final List<_ScriptedProbe> created = <_ScriptedProbe>[];

  _ScriptedProbe Function(int port)? make;

  LinkProbe factory(String speedUrl, String latencyUrl, int port) {
    speedUrls.add(speedUrl);
    latencyUrls.add(latencyUrl);
    final builder = make;
    final probe =
        builder != null ? builder(port) : _ScriptedProbe(localPort: port);
    created.add(probe);
    return probe;
  }
}

/// 「扮演本机 Xray 入站」的本地服务：按路径分流，并记录每条被请求的路径。
class _LocalInbound {
  _LocalInbound._(this._server, this.paths);

  final HttpServer _server;
  final List<String> paths;

  int get port => _server.port;

  static Future<_LocalInbound> start(
    Future<void> Function(HttpRequest request) handler,
  ) async {
    final paths = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      paths.add(request.uri.path);
      unawaited(handler(request).catchError((Object _) {}));
    });
    return _LocalInbound._(server, paths);
  }

  Future<void> close() => _server.close(force: true);
}

Future<void> _respond(
  HttpRequest request, {
  int status = 200,
  int delayMs = 0,
  int bodyBytes = 1024,
}) async {
  if (delayMs > 0) await Future<void>.delayed(Duration(milliseconds: delayMs));
  final resp = request.response;
  resp.statusCode = status;
  resp.contentLength = bodyBytes;
  if (bodyBytes > 0) resp.add(List<int>.filled(bodyBytes, 0x41));
  await resp.close();
}

/// 让出事件循环，直到 [condition] 成立（最多等 [timeout]）。
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待条件超时（${timeout.inMilliseconds}ms）');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  // =========================================================================
  // 一、闸门许可不能被抬高（Bug A 修法的第二类风险）
  //
  // 修法依赖 `Semaphore.reopen()`，而 reopen **不重置 permits**；`release()` 会给
  // `_permits++`。所以必须验「取消后上一轮迟到的 release 会不会把许可数抬到初始值
  // 之上」——一旦抬高，并发上限被静默突破，测速读数会被并发瓜分，比原 bug 更难发现。
  //
  // 审计结论（本组用例即证据）：**不会抬高**。原因不是 reopen 重置了 permits
  // （它没有），而是 drain 会清空等待队列、release 只与成功 acquire 配对，
  // 没有「凭空 +1」的入口。但这一结论必须由行为断言守住，不能只靠读代码。
  // =========================================================================
  group('闸门许可：drain / reopen / 迟到 release 的组合不能抬高 permits', () {
    test('先 reopen 再收尾 → permits 恰好回到初始值（等于 runner 的正确顺序）', () async {
      final gate = Semaphore(kLatencyParallel, name: 'audit-latency');

      // 一轮：6 个在跑，各占一个许可
      for (var i = 0; i < kLatencyParallel; i++) {
        await gate.acquire();
      }
      expect(gate.permits, 0, reason: '6 个许可全被占满');

      // 用户点取消：drain 关闸（在跑的不被打断，等它们自己 finally）
      gate.drain();
      expect(gate.drained, isTrue);

      // 下一轮 _runOnce 开头 reopen（此时上一轮已全部收尾 —— 见下一条用例）
      gate.reopen();

      // 上一轮 6 个探测的 finally 迟到归还
      for (var i = 0; i < kLatencyParallel; i++) {
        gate.release();
      }

      expect(
        gate.permits,
        kLatencyParallel,
        reason: 'permits 必须恰好回到 6；大于 6 就是并发上限被突破',
      );
      expect(gate.drained, isFalse);
    });

    test('任意 drain / reopen / release 交错，permits 都不会超过初始值（不会虚增）', () async {
      final gate = Semaphore(kLatencyParallel, name: 'audit-latency');
      var maxSeen = gate.permits;

      // 交替制造：在跑（已 acquire）、排队（acquire 未返回）、取消（drain）、
      // 下一轮（reopen）、迟到归还（release）。
      for (var i = 0; i < 12; i++) {
        await gate.acquire(); // 在跑
        gate.drain(); // 用户取消
        gate.reopen(); // 下一轮 _runOnce 开头
        gate.release(); // 本轮探测的 finally 迟到归还
        if (gate.permits > maxSeen) maxSeen = gate.permits;
      }

      // 这一段的关键结论：**许可不可能被抬高**。
      // 原因不是 reopen 会重置 permits（它不重置），而是两条结构性约束：
      // ① `drain()` 会把等待队列整体清空（排队者拿不到许可，也就没有对应的 release）；
      // ② `release()` 只与成功返回的 `acquire()` 一一配对（`withPermit` 的 finally），
      //    所以「凭空 +1」没有入口。
      expect(
        maxSeen,
        kLatencyParallel,
        reason: 'permits 一旦能超过 6，下一轮并发上限就被静默突破（读数被瓜分）',
      );
      expect(gate.permits, kLatencyParallel, reason: '全部归还后必须回到初始值');
      expect(gate.waiting, 0, reason: 'drain 后不得留下孤儿等待者');
      expect(gate.drained, isFalse);
    });

    test('两轮「取消 + 收尾」之后，runner 的延迟并发峰值仍然只能是 6', () async {
      var inFlight = 0;
      var peak = 0;
      final sink = _ProbeSink()
        ..make = (port) => _ScriptedProbe(
              localPort: port,
              onLatency: (probe) async {
                inFlight++;
                if (inFlight > peak) peak = inFlight;
                try {
                  await probe.cancelSignal;
                  return LinkProbeOutcome.cancelledAt(1);
                } finally {
                  inFlight--;
                }
              },
            );
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[for (var i = 0; i < 8; i++) 20000 + i]),
        probeFactory: sink.factory,
      );
      const links = <String>[
        'vless://uuid-1@h0.example:443?type=ws',
        'vless://uuid-2@h1.example:443?type=ws',
        'vless://uuid-3@h2.example:443?type=ws',
        'vless://uuid-4@h3.example:443?type=ws',
        'vless://uuid-5@h4.example:443?type=ws',
        'vless://uuid-6@h5.example:443?type=ws',
        'vless://uuid-7@h6.example:443?type=ws',
        'vless://uuid-8@h7.example:443?type=ws',
      ];

      for (var round = 0; round < 3; round++) {
        final future = runner.run(links, mode: LinkTestMode.latency);
        await _until(() => inFlight == kLatencyParallel);
        await runner.cancel();
        await future;
      }

      expect(
        peak,
        kLatencyParallel,
        reason: '三轮（穿插取消）之后许可数被抬高的唯一表现就是峰值 > 6',
      );
      expect(runner.running, isFalse);
    });

    test('三轮之后，速度闸门仍只放 2 路（8 个候选 → 峰值 2）', () async {
      var speedInFlight = 0;
      var speedPeak = 0;
      var round = 0;
      final sink = _ProbeSink();
      sink.make = (port) {
        // 前两轮：延迟挂住 → 必被取消（两个闸门都被 drain 一遍）
        if (round < 2) {
          return _ScriptedProbe(
            localPort: port,
            onLatency: _hangUntilCancelled,
          );
        }
        // 第三轮：正常出数，顺带测速度阶段的实际并发
        return _ScriptedProbe(
          localPort: port,
          onSpeed: (_) async {
            speedInFlight++;
            if (speedInFlight > speedPeak) speedPeak = speedInFlight;
            await Future<void>.delayed(const Duration(milliseconds: 15));
            speedInFlight--;
            return const LinkProbeOutcome(
              ttfbMs: 20,
              speedMib: 1.0,
              elapsedMs: 100,
            );
          },
        );
      };
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[for (var i = 0; i < 8; i++) 20000 + i]),
        probeFactory: sink.factory,
      );
      const links = <String>[
        'vless://uuid-1@h0.example:443?type=ws',
        'vless://uuid-2@h1.example:443?type=ws',
        'vless://uuid-3@h2.example:443?type=ws',
        'vless://uuid-4@h3.example:443?type=ws',
        'vless://uuid-5@h4.example:443?type=ws',
        'vless://uuid-6@h5.example:443?type=ws',
        'vless://uuid-7@h6.example:443?type=ws',
        'vless://uuid-8@h7.example:443?type=ws',
      ];

      // 先取消两轮（把两个闸门都 drain 一遍），第三轮再出数
      for (var i = 0; i < 2; i++) {
        round = i;
        final future = runner.run(links, mode: LinkTestMode.latency);
        await _until(() => sink.created.length >= (i + 1) * kLatencyParallel);
        await runner.cancel();
        await future;
        expect(runner.cancelled, isTrue);
      }

      round = 2;
      final run = await runner.run(links, mode: LinkTestMode.auto);
      expect(run.results.where((r) => r.state == ProbeState.done).length, 8);
      expect(
        speedPeak,
        kSpeedParallel,
        reason: '速度闸门若被抬高，8 个候选会同时开跑，测出的是被瓜分的带宽',
      );
    });
  });

  // =========================================================================
  // 二、取消的四种边界时刻：第二轮都必须拿到 done
  // =========================================================================
  group('取消边界时刻', () {
    test('取消发生在延迟阶段中间 → 第二轮 done', () async {
      var round = 0;
      final sink = _ProbeSink();
      sink.make = (port) {
        // 第一轮延迟挂住；第二轮立刻回。
        final isFirst = round == 0;
        return _ScriptedProbe(
          localPort: port,
          onLatency: isFirst ? _hangUntilCancelled : _defaultLatency,
        );
      };
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[20000]),
        probeFactory: sink.factory,
      );

      final first = runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);
      await _until(() => sink.created.isNotEmpty);
      await runner.cancel();
      final firstRun = await first;
      expect(firstRun.results.single.state, ProbeState.cancelled);

      round = 1;
      final second = await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);
      expect(second.results.single.state, ProbeState.done);
      expect(second.results.single.latencyMs, 10);
    });

    test('取消发生在速度阶段中间 → 第二轮 done（速度闸门也被 drain 过）', () async {
      var speedStarted = Completer<void>();
      var round = 0;
      final sink = _ProbeSink();
      sink.make = (port) => _ScriptedProbe(
            localPort: port,
            onSpeed: (probe) async {
              if (round == 0) {
                if (!speedStarted.isCompleted) speedStarted.complete();
                await probe.cancelSignal;
                return LinkProbeOutcome.cancelledAt(1);
              }
              return _defaultSpeed(probe);
            },
          );
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[20000]),
        probeFactory: sink.factory,
      );

      final first = runner.run(<String>[_link('a.example', 443)]);
      await speedStarted.future.timeout(const Duration(seconds: 5));
      await runner.cancel();
      final firstRun = await first;
      expect(firstRun.results.single.state, ProbeState.cancelled);
      expect(firstRun.results.single.speedMib, isNull,
          reason: '速度没测出来就是 null，不能因为取消退化成 0.0');

      round = 1;
      speedStarted = Completer<void>();
      final second = await runner.run(<String>[_link('a.example', 443)]);
      expect(second.results.single.state, ProbeState.done);
      expect(second.results.single.speedMib, 1.5,
          reason: '速度闸门若没 reopen，第二轮速度阶段会整批 cancelled');
    });

    test('全部条目还没派发就取消（卡在批量启动）→ 第二轮 done', () async {
      final gate = Completer<void>();
      final xray = _FakeXray(startGate: gate);
      final sink = _ProbeSink();
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: xray,
        pool: _FixedPool(<int>[20000]),
        probeFactory: sink.factory,
      );

      final first = runner.run(<String>[_link('a.example', 443)]);
      await _until(() => xray.startCalls >= 1);
      await runner.cancel();
      gate.complete(); // 让第一轮继续往下走（它会发现已取消）

      final firstRun = await first;
      expect(
        firstRun.results.single.state,
        ProbeState.cancelled,
        reason: '一个探测都没发，条目也必须落到 cancelled（不能停在 pending）',
      );
      expect(sink.created, isEmpty, reason: '取消后不得再派发探测');

      final second = await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);
      expect(second.results.single.state, ProbeState.done);
    });

    test('取消后不 await 立即重测：第一轮的结果不被第二轮覆盖（不串行）', () async {
      var round = 0;
      final sink = _ProbeSink();
      sink.make = (port) => _ScriptedProbe(
            localPort: port,
            onLatency: round == 0 ? _hangUntilCancelled : _defaultLatency,
          );
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[20000]),
        probeFactory: sink.factory,
      );

      final first = runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);
      await _until(() => sink.created.isNotEmpty);

      final cancelling = runner.cancel();
      round = 1;
      final second = runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);
      await cancelling;

      final firstRun = await first;
      final secondRun = await second;
      expect(firstRun.results.single.state, ProbeState.cancelled,
          reason: '第一轮的 run 对象是快照，第二轮不得改写它');
      expect(firstRun.results.single.latencyMs, -1);
      expect(secondRun.results.single.state, ProbeState.done);
      expect(secondRun.results.single.latencyMs, 10);
      expect(
        identical(firstRun.results, secondRun.results),
        isFalse,
        reason: '两轮必须是两份结果，不能共用一个 list（否则结果归属错行）',
      );
    });
  });

  // =========================================================================
  // 三、语义不许退化
  // =========================================================================
  group('语义保持', () {
    test('真重入（上一轮没取消）仍必须抛「上一次测速还在进行」', () async {
      final sink = _ProbeSink()
        ..make = (port) => _ScriptedProbe(
              localPort: port,
              onLatency: _hangUntilCancelled,
            );
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[20000]),
        probeFactory: sink.factory,
      );

      final first = runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);
      await _until(() => sink.created.isNotEmpty);

      // 收窄到「未取消」这一种情形：这正是旧行为，必须原样保留
      await expectLater(
        runner.run(<String>[_link('b.example', 8443)],
            mode: LinkTestMode.latency),
        throwsA(isA<LinkTestException>().having(
          (e) => e.message,
          'message',
          contains('上一次测速还在进行'),
        )),
      );

      // 第一轮不受第二次调用影响
      expect(runner.running, isTrue);
      await runner.cancel();
      final firstRun = await first;
      expect(firstRun.results.single.state, ProbeState.cancelled);
      expect(firstRun.results, hasLength(1), reason: '第二次调用不能污染第一轮的结果表');
    });

    test('cancelled 与 failed 不混用：取消 → cancelled 且 error 为 null', () async {
      final sink = _ProbeSink()
        ..make = (port) => _ScriptedProbe(
              localPort: port,
              onLatency: _hangUntilCancelled,
            );
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[20000]),
        probeFactory: sink.factory,
      );

      final future = runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);
      await _until(() => sink.created.isNotEmpty);
      await runner.cancel();
      final run = await future;

      final result = run.results.single;
      expect(result.state, ProbeState.cancelled);
      expect(result.error, isNull, reason: '取消不是失败，不能挂 error 文案');
      expect(result.ok, isFalse, reason: 'cancelled ≠ ok');
      expect(result.hasSpeed, isFalse);
    });

    test('cancelled 与 failed 不混用：探测报错 → failed 且 error 有文案', () async {
      final sink = _ProbeSink()
        ..make = (port) => _ScriptedProbe(
              localPort: port,
              onLatency: (_) async =>
                  LinkProbeOutcome.failure('连接失败：refused', 5),
            );
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[20000]),
        probeFactory: sink.factory,
      );

      final run = await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);

      final result = run.results.single;
      expect(result.state, ProbeState.failed);
      expect(result.error, isNotNull);
      expect(result.state == ProbeState.cancelled, isFalse);
    });

    test('预热未完成：速度记「未测」（null），绝不能退化成 0.0', () async {
      final sink = _ProbeSink()
        ..make = (port) => _ScriptedProbe(
              localPort: port,
              onSpeed: (_) async => const LinkProbeOutcome(
                ttfbMs: 30,
                error: kProbeWarmupIncomplete,
                elapsedMs: 3000,
              ),
            );
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[20000]),
        probeFactory: sink.factory,
      );

      final run = await runner.run(<String>[_link('a.example', 443)]);

      final result = run.results.single;
      expect(result.state, ProbeState.failed);
      expect(result.error, kProbeWarmupIncomplete);
      expect(result.speedMib, isNull, reason: 'null = 未测；写成 0.0 会被排序当成最慢');
      expect(result.hasSpeed, isFalse);
      // 延迟阶段的数不能被速度阶段抹掉（AUTO 的诊断价值）
      expect(result.latencyMs, 10);
      expect(run.fastest, 0, reason: '没有可用速度时 fastest 兜底 0，但单项仍是 null');
    });
  });

  // =========================================================================
  // 四、204 / 4xx / 5xx：两种语义不能合并
  // =========================================================================
  group('延迟判定：204 可达，4xx/5xx 失败', () {
    test('204 No Content → 可达，且不是 kProbeNoData', () async {
      final inbound = await _LocalInbound.start(
        (req) => _respond(req, status: HttpStatus.noContent, bodyBytes: 0),
      );
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: _speedUrl,
        latencyUrl: 'http://audit.test/generate_204',
        localPort: inbound.port,
      );

      final outcome = await probe.latency();

      expect(outcome.error, isNull);
      expect(outcome.error, isNot(kProbeNoData));
      expect(outcome.cancelled, isFalse);
      expect(outcome.latencyKnown, isTrue);
      expect(outcome.timings!.firstByteMs, -1, reason: '204 没有 body');
      expect(outcome.ttfbMs, outcome.timings!.headerMs);
    });

    test('200 却一个字节都没有 → 仍然 kProbeNoData（这条语义不能被 204 放宽掉）', () async {
      final inbound = await _LocalInbound.start(
        (req) => _respond(req, bodyBytes: 0),
      );
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: _speedUrl,
        latencyUrl: 'http://audit.test/generate_204',
        localPort: inbound.port,
      );

      final outcome = await probe.latency();

      expect(outcome.error, kProbeNoData);
      expect(outcome.ok, isFalse);
    });

    test('500 → 失败且文案带状态码（不是「没有读到数据」）', () async {
      final inbound = await _LocalInbound.start(
        (req) => _respond(req, status: 500, bodyBytes: 16),
      );
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: _speedUrl,
        latencyUrl: 'http://audit.test/generate_204',
        localPort: inbound.port,
      );

      final outcome = await probe.latency();

      expect(outcome.error, 'HTTP 500');
      expect(outcome.ok, isFalse);
      expect(outcome.timings, isNotNull);
    });

    test('速度阶段必须继续跟随跳转（302 → 200 大 body 要能测出速度）', () async {
      final inbound = await _LocalInbound.start((req) async {
        if (req.uri.path.contains('300.zip')) {
          final resp = req.response;
          resp.statusCode = HttpStatus.found;
          resp.headers
              .set(HttpHeaders.locationHeader, 'http://cdn.test/blob.bin');
          resp.contentLength = 0;
          await resp.close();
          return;
        }
        // 跳转后的真实目标：够一个窗口的 body
        const total = kWarmupBytes + 2 * 1024 * 1024;
        final resp = req.response;
        resp.statusCode = 200;
        resp.contentLength = total;
        resp.add(List<int>.filled(total, 0x41));
        await resp.close();
      });
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: _speedUrl,
        latencyUrl: 'http://audit.test/generate_204',
        localPort: inbound.port,
        // 窗口按 3s 预算，本地球回得快，会提前到达 maxBytes/budget
      );

      final outcome = await probe.speed();

      expect(
        outcome.error,
        isNull,
        reason: '大文件端点 302 到 CDN 是常态；关掉 followRedirects 会让测速全挂',
      );
      expect(outcome.speedMib, isNotNull);
      expect(outcome.speedMib, greaterThan(0));
      expect(outcome.timings!.redirects, 1, reason: '跨主机 302 必须被跟随一次');
      expect(
        inbound.paths.where((p) => p.contains('300.zip')).length,
        1,
        reason: '入口请求只发一次，跳转由 SDK 在连接层完成',
      );
    });
    test('5s 死线 + 8s 建连超时：端点接了却不回响应，错误必须可读（不能是空串/难懂）', () async {
      // 复刻「延迟超时 12s→5s，而 kConnectTimeout 仍是 8s」这个组合：
      // 死线比建连超时更短，意味着**看门狗会先触发**（force close 打断在途请求），
      // 用户拿到的错误来自 close 抛出的异常，而不是一条正常的超时文案。
      // 这里把死线缩到 400ms 保持「死线 < 建连」的比例，测试才够快。
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((_) {
        // 接了连接，但**永不回响应头**，也永不关闭
      });
      addTearDown(() => server.close(force: true));

      final probe = LinkProbe(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        localPort: server.port,
        connectTimeout: const Duration(seconds: 8), // = kConnectTimeout
        latencyTimeout: const Duration(milliseconds: 400), // 缩短的「5s 死线」
      );

      final sw = Stopwatch()..start();
      final outcome = await probe.latency();
      sw.stop();

      // 1) 死线必须真的生效：远早于 connectTimeout(8s) 返回
      expect(sw.elapsedMilliseconds, lessThan(3000),
          reason: '看门狗应在死线附近打断，而不是傻等 8s 建连超时');

      // 2) 失败且原因非空、可读
      expect(outcome.ok, isFalse);
      expect(outcome.error, isNotNull, reason: '失败必须带原因，不能是 null');
      expect((outcome.error ?? '').trim(), isNotEmpty, reason: '不能是空字符串');
      expect(outcome.error, isNot('null'));
      expect(outcome.error, isNot(kProbeNoData),
          reason: '端点挂死不是「没读到数据」，两种失败不能混成一个文案');
      // 3) 实测结论（本条用例就是为此而写）：
      //    「死线 5s < 建连 8s」这个组合下，看门狗 force close 打断在途请求后，
      //    `humanizeProbeError` 拿到的是 TimeoutException → 文案是**「超时」**，
      //    既不是空串，也不是 `HttpException: Connection closed before full
      //    header was received` 这类英文堆栈。也就是说这个退化风险不成立。
      expect(outcome.error, kProbeTimeout,
          reason: '看门狗掐断在途请求时必须是 kProbeTimeout（「超时」），'
              '不能退化成 HttpException 的英文原文或空串');
      // 4) 记录实际文案，写进 QA 报告
      // ignore: avoid_print
      print(
          'QATIMEOUT_ERROR=${outcome.error} elapsed=${sw.elapsedMilliseconds}ms');
    });
  });
  // =========================================================================
  // 五、端点分流：延迟走 latencyUrl，速度走 speedUrl
  // =========================================================================
  group('两个端点必须真正分流', () {
    test('probe 级：latency() 只打延迟端点，speed() 只打测速端点', () async {
      final inbound = await _LocalInbound.start((req) async {
        if (req.uri.path.contains('generate_204')) {
          await _respond(req, status: HttpStatus.noContent, bodyBytes: 0);
          return;
        }
        const total = kWarmupBytes + 2 * 1024 * 1024;
        await _respond(req, bodyBytes: total);
      });
      addTearDown(inbound.close);

      final latencyProbe = LinkProbe(
        speedUrl: _speedUrl,
        latencyUrl: 'http://audit.test/generate_204',
        localPort: inbound.port,
      );
      final latencyOutcome = await latencyProbe.latency();
      expect(latencyOutcome.ok, isTrue, reason: '打的是延迟端点（204 无 body）→ 必须判可达');
      expect(inbound.paths, <String>['/generate_204'],
          reason: 'latency() 不得碰 /300.zip');

      final speedProbe = LinkProbe(
        speedUrl: _speedUrl,
        latencyUrl: 'http://audit.test/generate_204',
        localPort: inbound.port,
      );
      final speedOutcome = await speedProbe.speed();
      expect(inbound.paths.last, '/300.zip',
          reason: 'speed() 不得碰 /generate_204');
      expect(speedOutcome.speedMib, isNotNull);
    });

    test('runner 级：probeFactory 收到的两个地址分别就是构造参数（没有互换）', () async {
      final sink = _ProbeSink();
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[20000]),
        probeFactory: sink.factory,
      );

      await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);

      expect(sink.speedUrls, <String>[_speedUrl]);
      expect(sink.latencyUrls, <String>[_latencyUrl]);
    });

    test('默认常量：延迟用小端点、速度用大文件端点，且互不相同', () {
      expect(kDefaultLatencyUrl, contains('generate_204'));
      expect(kDefaultSpeedUrl, contains('300.zip'));
      expect(kDefaultLatencyUrl, isNot(kDefaultSpeedUrl));

      final probe = LinkProbe(localPort: 1);
      expect(probe.latencyUri.path, '/generate_204');
      expect(probe.uri.path, '/300.zip');
      expect(probe.latencyUri.host, isNot(probe.uri.host));
    });
  });

  // =========================================================================
  // 七、AppState 层的副本状态：「取消 → 立刻再测」时结果归属不能错行
  //
  // runner 层用 `_epoch` / `_isCurrent` 守住结果表，但 `AppState` 还有一份副本
  // （linkResults / linkStage / linkTestRunning）。第一轮 `runLinkTest` 的 await
  // 会在**第二轮已经开跑之后**才恢复执行，此时它若照旧写这三个字段，就会用
  // 「第一轮的已取消结果 + 完成态」覆盖第二轮 —— 用户看到「完成」但其实还在测。
  // =========================================================================
  group('AppState：第一轮收尾不得改写第二轮的状态', () {
    test('取消后立刻再测：第二轮在跑时，UI 状态不能被第一轮的收尾改成「完成」', () async {
      var round = 0;
      final sink = _ProbeSink();
      sink.make = (port) => _ScriptedProbe(
            localPort: port,
            onLatency: (probe) async {
              if (round == 0) {
                await probe.cancelSignal;
                return LinkProbeOutcome.cancelledAt(1);
              }
              // 第二轮故意慢一点，好在「第一轮收尾之后」观察中间态
              await Future<void>.delayed(const Duration(milliseconds: 80));
              return _defaultLatency(probe);
            },
          );
      final state = AppState(
        runner: LinkTestRunner(
          speedUrl: _speedUrl,
          latencyUrl: _latencyUrl,
          xray: _FakeXray(),
          pool: _FixedPool(<int>[20000]),
          probeFactory: sink.factory,
        ),
      );

      final first = state.runLinkTest(
        <String>[_link('a.example', 443)],
        mode: LinkTestMode.latency,
      );
      await _until(() => sink.created.isNotEmpty);

      // 用户手速：点「取消」后不等收尾就点「开始」
      final cancelling = state.cancelLinkTest();
      round = 1;
      final second = state.runLinkTest(
        <String>[_link('a.example', 443)],
        mode: LinkTestMode.latency,
      );
      await cancelling;
      await first; // 第一轮的收尾在这一刻完成

      expect(
        state.linkTestRunning,
        isTrue,
        reason: '第二轮还在跑，第一轮的 finally 不能把「在跑」标成「没跑」',
      );
      expect(
        state.linkStage,
        isNot('完成'),
        reason: '第二轮刚开跑，第一轮不能把阶段写成「完成」',
      );
      expect(
        state.linkResults.where((r) => r.state == ProbeState.cancelled),
        isEmpty,
        reason: '第一轮的已取消快照不能落到 UI（结果归属错行）；'
            '此刻第二轮可能还没出一行，所以断言「不存在 cancelled 行」而不是「必有一行」',
      );

      final secondOk = await second;
      expect(secondOk, isTrue);
      expect(state.linkTestRunning, isFalse);
      expect(state.linkResults.single.state, ProbeState.done);
      expect(state.linkResults.single.latencyMs, 10);
    });
  });

  // =========================================================================
  // 九、设置页换端点：两条口径（延迟/速度）不许被合成一条
  //
  // 设置页保存后会 `configureUrls(...)`。若实现把两个地址灌成同一个字段，
  // 就等于把 Bug B 从「默认值」搬进了「用户可配」——更难发现（用户改完端点，
  // 延迟读数又变脏）。空串必须等价于「恢复默认」，不能拿去探测。
  // =========================================================================
  group('设置页换端点', () {
    test('构造时传空串/纯空格：两个端点都回落到默认（不能拿着空地址去探测）', () async {
      final sink = _ProbeSink();
      final runner = LinkTestRunner(
        speedUrl: '   ',
        latencyUrl: '',
        xray: _FakeXray(),
        pool: _FixedPool(<int>[20000]),
        probeFactory: sink.factory,
      );

      expect(runner.speedUrl, kDefaultSpeedUrl,
          reason: '空地址会让每条线路都报「地址非法」，必须回落到默认大文件端点');
      expect(runner.latencyUrl, kDefaultLatencyUrl, reason: '延迟端点同理，回落默认小端点');

      await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);
      expect(sink.latencyUrls.single, isNotEmpty);
      expect(sink.latencyUrls.single, kDefaultLatencyUrl);
    });

    test('保存时传空串（用户在设置页把输入框删空）：端点不能被改成空', () async {
      final sink = _ProbeSink();
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[20000]),
        probeFactory: sink.factory,
      );

      runner.configureUrls(speedUrl: '', latencyUrl: '   ');

      expect(runner.speedUrl, isNotEmpty, reason: '端点绝不能变成空串');
      expect(runner.latencyUrl, isNotEmpty);
      // 关键：整批不会被「地址非法」测死 —— 探测拿到的仍是可用地址
      final run = await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);
      expect(run.results.single.state, ProbeState.done,
          reason: '空串被忽略后应当照常测出结果，而不是整批报「地址非法」');
      expect(sink.latencyUrls.single, isNotEmpty);
    });

    test('只改速度地址：延迟仍打原来的小端点（两条口径独立）', () async {
      final sink = _ProbeSink();
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[20000]),
        probeFactory: sink.factory,
      );

      runner.configureUrls(speedUrl: 'http://cdn.test/big.bin');

      expect(runner.speedUrl, 'http://cdn.test/big.bin');
      expect(runner.latencyUrl, _latencyUrl, reason: '只改速度地址，不能顺手把延迟地址也改掉');

      await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);
      expect(sink.latencyUrls.single, _latencyUrl);
      expect(sink.speedUrls.single, 'http://cdn.test/big.bin');
    });

    // 语义在 08:5x 被需求方改过（team-lead 明确要求）：空串/纯空格 =
    // **重置为默认**，不再是「忽略」。原断言（保持旧值）已不成立，
    // 由工程师按新语义改写，并同步给 QA 复核。
    // 理由：用户「先设自定义 → 清空输入框 → 保存」时，忽略空串会让同一会话
    // 里继续用那个自定义值，只有重启才回落 —— 「清空」与「恢复默认」在用户
    // 眼里是同一件事，行为不一致就是 bug；正确性也不该只押在设置页的归一化上。
    test('空串 / 纯空格一律**重置为默认**（端点不会变空，也不留着旧自定义值）', () {
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: _FakeXray(),
      );

      runner.configureUrls(speedUrl: '   ', latencyUrl: '');
      expect(runner.speedUrl, kDefaultSpeedUrl);
      expect(runner.latencyUrl, kDefaultLatencyUrl);
      expect(runner.speedUrl, isNotEmpty, reason: '无论如何都不能把端点变成空串');
    });

    test('运行中换地址只影响下一轮：同一轮的延迟与速度必须是同一批端点', () async {
      final sink = _ProbeSink();
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[20000]),
        probeFactory: sink.factory,
      );

      final future = runner.run(<String>[_link('a.example', 443)]);
      await _until(() => sink.created.isNotEmpty);
      runner.configureUrls(
        speedUrl: 'http://other.test/big.bin',
        latencyUrl: 'http://other.test/204',
      );
      await future;

      expect(sink.speedUrls.every((u) => u == _speedUrl), isTrue,
          reason: '同一轮内换地址会让延迟与速度打到不同端点，读数不可比');
      expect(sink.latencyUrls.every((u) => u == _latencyUrl), isTrue);
    });
  });

  // =========================================================================
  // 十、未覆盖风险自查：延迟端点整批不可达时，用户看到什么
  //
  // 本机无外网，这里用「一定没人监听的本机端口」模拟「cp.cloudflare.com 在
  // 真机上被墙 / 不可用」。要回答两个问题：失败原因是否可读？会不会被误判成
  // 「所有节点都挂了」？
  // =========================================================================
  group('风险自查：延迟端点不可达', () {
    test('每条都有可读失败原因，且 AUTO 不会对失败项再去测速度', () async {
      // 拿一个「一定没人监听」的端口当本机入站 → 探测必然立刻连接失败
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();

      final created = <_CountingProbe>[];
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[deadPort, deadPort, deadPort]),
        probeFactory: (speed, latency, port) {
          final p = _CountingProbe(
            speedUrl: speed,
            latencyUrl: latency,
            localPort: port,
            connectTimeout: const Duration(milliseconds: 300),
            latencyTimeout: const Duration(seconds: 1),
          );
          created.add(p);
          return p;
        },
      );

      final run = await runner.run(<String>[
        _link('a.example', 443),
        _link('b.example', 443),
        _link('c.example', 443),
      ]);

      expect(run.results, hasLength(3));
      expect(run.results.every((r) => r.state == ProbeState.failed), isTrue);
      for (final result in run.results) {
        expect(result.error, isNotNull);
        expect(
          result.error,
          anyOf(contains('连接失败'), contains('超时'), contains('TLS')),
          reason: '失败原因必须是用户能读懂的一句话，不能是 errno/堆栈',
        );
        // 不能出现「没读到数据」这种会把「端点被封」误导成「端点有问题」之外的口径
        expect(result.error, isNot(kProbeNoData));
      }
      expect(
        created.every((p) => p.speedCalls == 0),
        isTrue,
        reason: 'AUTO 只对有响应的节点测速，失败项不许空转 3s',
      );
      expect(run.okCount, 0);
    });
  });

  // =========================================================================
  // 八、接线完整性：onLog → AppState.logs → LogPanel
  // =========================================================================
  group('接线：分项计时能到用户眼前', () {
    test('runner 自己会把「端点 + 延迟段分项 + 速度段分项」拼成日志', () async {
      final logs = <String>[];
      final sink = _ProbeSink();
      sink.make = (port) => _ScriptedProbe(
            localPort: port,
            onLatency: (_) async => const LinkProbeOutcome(
              ttfbMs: 21,
              elapsedMs: 25,
              timings: ProbeTimings(
                connectMs: 3,
                headerMs: 21,
                firstByteMs: 21,
              ),
            ),
            onSpeed: (_) async => const LinkProbeOutcome(
              ttfbMs: 40,
              speedMib: 2.5,
              elapsedMs: 3200,
              timings: ProbeTimings(
                connectMs: 2,
                headerMs: 40,
                firstByteMs: 45,
                redirects: 1,
              ),
            ),
          );
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[20000]),
        probeFactory: sink.factory,
        onLog: logs.add,
      );

      await runner.run(<String>[_link('node-a.example', 443)]);

      expect(
        logs.any((l) =>
            l.contains('端点：延迟=$_latencyUrl') && l.contains('速度=$_speedUrl')),
        isTrue,
        reason: '开测第一行必须交代「延迟探的是哪个地址」',
      );
      expect(
        logs.any((l) => l.contains('延迟 ') && l.contains('建连=3 响应头=21 首字节=21')),
        isTrue,
        reason: '延迟阶段必须在日志里留下分项计时（排障全靠它区分建连慢/对端慢）',
      );
      expect(
        logs.any((l) =>
            l.contains('速度 ') &&
            l.contains('速度=2.50MiB/s') &&
            l.contains('跳转=1')),
        isTrue,
        reason: '速度阶段的分项（含跳转次数）同样要可见',
      );
    });

    test('注入 runner 时也会补接 onLog（ensureLogSink），日志不丢', () async {
      // 这条守的是可测性缺陷：`runner ?? LinkTestRunner(..., onLog: pushLog)`
      // 只在**不注入**时接线，注入方会静默丢掉测速日志 —— 测试页日志面板一片空白。
      final sink = _ProbeSink();
      final state = AppState(
        runner: LinkTestRunner(
          speedUrl: _speedUrl,
          latencyUrl: _latencyUrl,
          xray: _FakeXray(),
          pool: _FixedPool(<int>[20000]),
          probeFactory: sink.factory,
        ),
      );

      await state.runLinkTest(<String>[_link('a.example', 443)],
          mode: LinkTestMode.latency);

      expect(
        state.logs.any((l) => l.contains('端点：延迟=$_latencyUrl')),
        isTrue,
        reason: '注入 runner 的路径也必须把 runner 的 onLog 接到 pushLog',
      );
    });

    test('什么都没在跑时点取消：不能凭空把阶段写成「已取消」', () async {
      // 注入 runner + 固定端口池：本用例不跑轮次，但**绝不能**让它去碰默认
      // PortPool（20000~20500 逐个 bind）—— 并发跑全量时会与别的测试文件撞端口。
      final state = AppState(
        runner: LinkTestRunner(
          speedUrl: _speedUrl,
          latencyUrl: _latencyUrl,
          xray: _FakeXray(),
          pool: _FixedPool(<int>[20000]),
        ),
      );

      await state.cancelLinkTest();

      expect(
        state.linkStage,
        isNot('已取消'),
        reason: 'runner.cancel() 在 !_running 时直接 return，UI 不该显示「已取消」',
      );
      expect(state.linkTestRunning, isFalse);
    });

    test('AppState 默认构造会把 runner 的 onLog 接到 logs（含端点与分项计时）', () async {
      // 不注入 runner，才走 `runner ?? LinkTestRunner(..., onLog: pushLog)` 分支。
      //
      // ⚠️ 这里**故意用一条无法解析的链接**，而不是一条合法 vless：
      // 合法链接会让默认 `PortPool` 去 20000~20499 逐个 bind 探活，再让真实
      // `LinkProbe` 连到 127.0.0.1:<那个端口>。在全量并发时，另一个测试文件
      // 可能正好占着同一端口 —— 于是探测连上了一个不会按 HTTP 回话的 socket，
      // 一路等到 `kLatencyTimeout`（实测把单轮拖到 16 分钟，看起来像死锁）。
      //
      // 无法解析的链接不会进 `nodes`，因此 `_runOnce` 会在打完「端点：…」这行
      // 日志之后**直接跳过端口分配与探测**（`if (nodes.isNotEmpty)` 分支不进入）。
      // 这条用例要验的只是 `onLog → pushLog` 的接线，不需要真的连一次；
      // 用它换掉一次无谓的真实 bind + socket，测试从分钟级降到毫秒级且完全确定。
      final state = AppState(xray: _FakeXrayProc());

      await state.runLinkTest(<String>['not-a-vless-link'],
          mode: LinkTestMode.latency);

      expect(
        state.logs.any((l) => l.contains('端点：延迟=') && l.contains('速度=')),
        isTrue,
        reason: '「延迟到底探的哪个地址」必须能从日志里确认（Bug B 的排障入口）',
      );
      expect(
        state.logs.any((l) => l.contains(kDefaultLatencyUrl)),
        isTrue,
        reason: '默认延迟端点必须出现在日志里',
      );
      // 证明确实跑了一轮（而不是被提前 return 掉）：那一条预检失败的结果必须在
      expect(state.linkResults, hasLength(1));
      expect(state.linkResults.single.state, ProbeState.failed);
      expect(state.linkResults.single.error, contains('链接无法解析'));
    });
  });
}

/// AppState 只接受 [XrayProc]，所以这里继承它并短路进程管理。
class _FakeXrayProc extends XrayProc {
  @override
  Future<String?> startBatch(List<(Vless, int)> nodes) async {
    debugSetModeForTest(XrayMode.batch);
    return null;
  }

  @override
  Future<void> stop() async {
    debugSetModeForTest(XrayMode.none);
  }
}

/// 真实 [LinkProbe] 的计数外壳：用来证明「AUTO 不会对失败项再去测速度」。
class _CountingProbe extends LinkProbe {
  _CountingProbe({
    required super.localPort,
    super.speedUrl,
    super.latencyUrl,
    super.connectTimeout,
    super.latencyTimeout,
  });

  int latencyCalls = 0;
  int speedCalls = 0;

  @override
  Future<LinkProbeOutcome> latency() {
    latencyCalls++;
    return super.latency();
  }

  @override
  Future<LinkProbeOutcome> speed() {
    speedCalls++;
    return super.speed();
  }
}
