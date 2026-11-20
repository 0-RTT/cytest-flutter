// QA 增量验证（严过关）：延迟阶段「候选端点 + 整批重试」。
//
// 待验语义（来自 team-lead 的 7 条）：
//  1. 整批一条都没拿到延迟 → 换下一个候选端点；
//  2. 只要有 ≥1 条拿到延迟 → 绝不切换；
//  3. 候选链最多试 3 次（首选 + 2 次切换）→ 第 4 个候选永不调用；
//  4. 重跑会重新派发探测，但**预检失败（链接无法解析）的 error 不能被清掉**；
//  5. 已拿到延迟的条目不参与重跑，且 latencyMs 不被覆盖；
//  6. 端点全挂时的最坏耗时放大倍数（可量化）；
//  7. 三条旧语义不许被碰：speedMib==null、cancelled≠failed、速度段仍跟随跳转。
//
// 外加两条我自己加的、针对「重试」这个新控制流的风险断言：
//  R1. 重试必须复用同一个闸门（否则切端点瞬间并发翻倍）；
//  R2. 取消要能打断重试循环（不能在 attempt 之间无视已取消）。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/link_probe.dart';
import 'package:cytest/data/link_test.dart';
import 'package:cytest/data/vless.dart';
import 'package:cytest/data/xray.dart';

// ---------------------------------------------------------------------------
// 夹具
// ---------------------------------------------------------------------------

final String _ep0 = kLatencyFallbackUrls[0];
final String _ep1 = kLatencyFallbackUrls[1];
const String _custom = 'http://custom.test/generate_204';
const String _speedUrl = 'http://speed.test/300.zip';

String _link(String host, int port) =>
    'vless://uuid-$port@$host:$port?type=ws&security=tls&sni=$host&path=%2Fws';

class _FakeXray implements BatchXray {
  int startCalls = 0;

  @override
  XrayMode mode = XrayMode.none;

  @override
  Future<String?> startBatch(List<(Vless, int)> nodes) async {
    startCalls++;
    await stop();
    mode = XrayMode.batch;
    return null;
  }

  @override
  Future<void> stop() async {
    mode = XrayMode.none;
  }
}

class _FixedPool extends PortPool {
  _FixedPool(this._ports);
  final List<int> _ports;

  @override
  Future<PortPick> pick(int n) async {
    final ports = _ports.take(n).toList(growable: false);
    return PortPick(ports: ports, missing: n - ports.length);
  }
}

/// 按「本探测拿到的延迟端点」决定结果的探针。
///
/// `onLatency` 收到的是 probe 自身（而不是 URL 字符串）：这样才能模拟
/// 真实 `LinkProbe.cancel()` 的行为 —— 关掉在途请求后立即返回一个
/// `cancelledAt`。否则 `runner.cancel()` 之后 `Future.wait` 永远等不到这一路，
/// 会表现成测试超时（其实是被测代码是对的，假件不肯收尾）。
class _UrlProbe extends LinkProbe {
  _UrlProbe({
    required super.localPort,
    required super.speedUrl,
    required super.latencyUrl,
    required this.onLatency,
  });

  final Future<LinkProbeOutcome> Function(_UrlProbe probe) onLatency;

  int latencyCalls = 0;
  int speedCalls = 0;

  /// runner 在调用 `latency()` 之前会把本轮死线写进 `latencyTimeout`。
  /// 记下来就能**实测**「首轮 8s / 重试轮 5s」，而不用真的等 8 秒。
  final List<Duration> observedDeadlines = <Duration>[];

  final Completer<void> _cancelSignal = Completer<void>();

  /// 本探测被 `cancel()` 的时刻（挂件用它模拟「关客户端后立刻收尾」）。
  Future<void> get cancelSignal => _cancelSignal.future;

  @override
  Future<LinkProbeOutcome> latency() {
    latencyCalls++;
    observedDeadlines.add(latencyTimeout);
    return onLatency(this);
  }

  @override
  Future<LinkProbeOutcome> speed() async {
    speedCalls++;
    return const LinkProbeOutcome(ttfbMs: 9, speedMib: 2.0, elapsedMs: 90);
  }

  @override
  void cancel() {
    super.cancel();
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
  }
}

/// 记录每次工厂调用拿到的两个地址 + 在飞峰值。
class _Recorder {
  final List<String> latencyUrls = <String>[];
  final List<String> speedUrls = <String>[];
  final List<_UrlProbe> probes = <_UrlProbe>[];

  Future<LinkProbeOutcome> Function(_UrlProbe probe)? onLatency;
  int inFlight = 0;
  int peak = 0;

  LinkProbe make(String speedUrl, String latencyUrl, int port) {
    latencyUrls.add(latencyUrl);
    speedUrls.add(speedUrl);
    final probe = _UrlProbe(
      localPort: port,
      speedUrl: speedUrl,
      latencyUrl: latencyUrl,
      onLatency: (probe) async {
        inFlight++;
        if (inFlight > peak) peak = inFlight;
        try {
          return await (onLatency ?? _fail)(probe);
        } finally {
          inFlight--;
        }
      },
    );
    probes.add(probe);
    return probe;
  }
}

/// 建连类失败（端点/线路真的不可达）——**只有这一类**才应该触发换端点。
Future<LinkProbeOutcome> _fail(_UrlProbe probe) async =>
    LinkProbeOutcome.failure(
      '连接失败：端点 ${probe.latencyUrl} 不可达',
      5,
      kind: ProbeFailureKind.connect,
    );

/// 超时类失败（慢但可能活着的节点）——按新规则**不**触发换端点。
Future<LinkProbeOutcome> _timeout(_UrlProbe probe) async =>
    LinkProbeOutcome.failure(
      kProbeTimeout,
      kLatencyTimeout.inMilliseconds,
      kind: ProbeFailureKind.timeout,
    );

Future<LinkProbeOutcome> _ok(_UrlProbe probe) async =>
    const LinkProbeOutcome(ttfbMs: 42, elapsedMs: 45);

LinkTestRunner _runner(
  _Recorder rec, {
  String latencyUrl = '',
  void Function(String message)? onLog,
}) =>
    LinkTestRunner(
      speedUrl: _speedUrl,
      latencyUrl: latencyUrl,
      xray: _FakeXray(),
      pool: _FixedPool(<int>[for (var i = 0; i < 10; i++) 20000 + i]),
      probeFactory: rec.make,
      onLog: onLog,
    );

void main() {
  group('候选端点 · 整批重试', () {
    test('1) 整批全失败 → 真的换到第二个候选（断言工厂实参，不看日志）', () async {
      final rec = _Recorder()
        // ep0 全失败，ep1 全成功
        ..onLatency = (probe) async =>
            probe.latencyUrl == _ep1 ? _ok(probe) : _fail(probe);
      final runner = _runner(rec, latencyUrl: ''); // 首选即 kDefaultLatencyUrl

      final run = await runner.run(<String>[
        _link('a.example', 443),
        _link('b.example', 443),
      ]);

      expect(rec.latencyUrls.toSet(), <String>{_ep0, _ep1},
          reason: '第一轮 ep0 全失败 → 必须切到 ep1，且只切一次');
      expect(rec.latencyUrls.where((u) => u == _ep1).length, 2,
          reason: 'ep1 上两条都要被重新派发');
      expect(run.results.every((r) => r.state == ProbeState.done), isTrue);
      expect(run.results.every((r) => r.latencyMs == 42), isTrue);
      expect(run.results.every((r) => r.error == null), isTrue,
          reason: '重试成功后旧的「端点不可达」error 必须被清掉');
    });

    test('2) 只要有 1 条拿到延迟 → 绝不切换（候选 2/3 零调用）', () async {
      final rec = _Recorder();
      // 只让第一条成功（同一端点上第一条探测返回 ok，其余返回失败）
      var call = 0;
      rec.onLatency = (probe) async {
        if (probe.latencyUrl == _ep0 && call++ == 0) return _ok(probe);
        return _fail(probe);
      };
      final runner = _runner(rec);

      final run = await runner.run(<String>[
        for (var i = 0; i < 6; i++) _link('h$i.example', 443),
      ], mode: LinkTestMode.latency);

      expect(rec.latencyUrls.toSet(), <String>{_ep0},
          reason: '已经有 1 条拿到延迟 → 端点没问题，失败的是真死链，不许切换');
      expect(rec.latencyUrls.length, 6, reason: '每节点只探测一次');
      expect(run.results.where((r) => r.latencyKnown).length, 1);
      expect(run.results.where((r) => r.state == ProbeState.done).length, 1);
    });

    test('3) 候选链最多试 3 次：第 4 个候选永不调用', () async {
      // 用户自定义首选（不在内置候选里）→ 候选链 = [custom, ep0, ep1, speedUrl]
      final rec = _Recorder()..onLatency = _fail;
      final runner = _runner(rec, latencyUrl: _custom);

      await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);

      expect(rec.latencyUrls, <String>[_custom, _ep0, _ep1],
          reason: 'kLatencyMaxAttempts=3：首选 + 2 次切换，第 4 个候选（speedUrl）不许出现');
      expect(rec.latencyUrls.contains(_speedUrl), isFalse,
          reason: '速度端点只允许在「候选链第 3 位之后」当兜底，绝不能越权成为第 4 次尝试');
    });

    test('4) 重跑会重发探测，但预检失败的 error 不被清掉（也不能被拿去重试）', () async {
      final rec = _Recorder()..onLatency = _fail;
      final runner = _runner(rec, latencyUrl: _custom);

      final run = await runner.run(<String>[
        'not-a-vless-link', // 预检失败
        _link('a.example', 443),
      ], mode: LinkTestMode.latency);

      final bad = run.results.firstWhere((r) => r.host.isEmpty);
      expect(bad.error, contains('链接无法解析'),
          reason: '预检失败是不可恢复的，重试不许把它清成「端点不可达」');
      expect(bad.state, ProbeState.failed);
      // 3 次尝试 × 1 个可测节点 = 3 次工厂调用（非法链接不该进探测）
      expect(rec.latencyUrls.length, 3, reason: '非法链接不能参与重跑（否则每次尝试都白多一个探测）');
    });

    test('5) 已拿到延迟的条目不参与重跑、latencyMs 不被覆盖', () async {
      // 6 条里只让第一条成功，其余全失败 → 不应发生切换（见用例 2），
      // 由此顺带证明成功项的 latencyMs 在整轮结束后仍是 42，没被任何后续尝试改写。
      var first = true;
      final rec = _Recorder()
        ..onLatency = (probe) async {
          if (first) {
            first = false;
            return _ok(probe);
          }
          return _fail(probe);
        };
      final runner = _runner(rec);

      final run = await runner.run(<String>[
        _link('a.example', 443),
        _link('b.example', 443),
        _link('c.example', 443),
      ], mode: LinkTestMode.latency);

      final okRows = run.results.where((r) => r.latencyKnown).toList();
      expect(okRows, hasLength(1));
      expect(okRows.single.latencyMs, 42, reason: '成功项的延迟不能被后续尝试覆盖');
      expect(run.results.where((r) => r.latencyKnown).length, 1,
          reason: '失败项不应因为重试而"变成"已知延迟');
    });

    test('6) 端点全挂：最坏耗时放大 ≈ 尝试次数 × 波数（量化，不靠"感觉可接受"）', () async {
      const perProbe = Duration(milliseconds: 120);
      final rec = _Recorder()
        ..onLatency = (probe) async {
          await Future<void>.delayed(perProbe);
          return _fail(probe);
        };
      final runner = _runner(rec, latencyUrl: _custom);

      final sw = Stopwatch()..start();
      await runner.run(<String>[
        for (var i = 0; i < 8; i++) _link('h$i.example', 443),
      ], mode: LinkTestMode.latency);
      sw.stop();

      // 8 节点 / 6 许可 = 2 波；3 次尝试 → 6 波
      expect(rec.probes, hasLength(24), reason: '3 次尝试 × 8 节点 = 24 次派发');
      final expected = perProbe.inMilliseconds * 6; // 6 波
      expect(sw.elapsedMilliseconds,
          greaterThanOrEqualTo((expected * 0.7).round()),
          reason: '最坏耗时 ≈ 尝试次数(3) × 波数(2) × 单次上界');
      expect(sw.elapsedMilliseconds, lessThan((expected * 2.2).round()),
          reason: '若明显超过 6 波，说明尝试之间有额外串行等待');
      // ignore: avoid_print
      print('QAFALLBACK_TIME 8节点×3尝试 = ${sw.elapsedMilliseconds}ms '
          '(单波 ${perProbe.inMilliseconds}ms；理论 ${expected}ms)');
    });
  });

  group('候选端点 · 阶段文案与日志', () {
    test('切换时阶段文案带「端点 n/m」，并打出换端点的日志', () async {
      final stages = <String>[];
      final logs = <String>[];
      // 首选(custom) 失败 → 第 2 个候选(ep0) 成功 → 恰好 2 次尝试
      final rec = _Recorder()
        ..onLatency = (probe) async =>
            probe.latencyUrl == _custom ? _fail(probe) : _ok(probe);
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _custom,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[20000]),
        probeFactory: rec.make,
        onLog: logs.add,
      );

      await runner.run(<String>[_link('a.example', 443)],
          mode: LinkTestMode.latency, onProgress: (_, stage) {
        if (!stages.contains(stage)) stages.add(stage);
      });

      final latencyStages =
          stages.where((s) => s.contains('延迟探测')).toList(growable: false);
      expect(latencyStages, hasLength(2), reason: '两次尝试 → 两个不同文案');
      expect(latencyStages[0], '延迟探测',
          reason: '首轮（attempt 0）不许带「端点 1/3」：健康网络 99% 在这一轮结束，'
              '带上计数会让人以为已经在重试');
      expect(latencyStages[1], contains('端点 2/3'), reason: '真的开始重试时才报「端点 n/m」');
      expect(
        logs.any((l) => l.contains('拿不到延迟') && l.contains('换下一个候选')),
        isTrue,
        reason: '换端点必须留日志，否则用户只看到「又等了一轮」不知道为什么',
      );
      // ignore: avoid_print
      print('QASTAGES=$latencyStages');
    });

    test('首轮不得出现「端点 1/」计数（健康网络下会被误读成已在重试）', () async {
      // 这条原本是把「瑕疵现状」固定下来（当时首轮就写「端点 1/3」）；
      // 修好之后它变成回归守护：一旦有人把计数加回 attempt 0，这里立刻红。
      final stages = <String>[];
      final rec = _Recorder()..onLatency = _ok;
      final runner = _runner(rec); // 首选即 kDefaultLatencyUrl，且它成功

      await runner.run(<String>[_link('a.example', 443)],
          mode: LinkTestMode.latency, onProgress: (_, stage) {
        if (stage.contains('延迟探测') && !stages.contains(stage)) {
          stages.add(stage);
        }
      });

      expect(stages, hasLength(1), reason: '一次就成功，不该有第二次尝试');
      expect(stages.single, '延迟探测', reason: '首轮文案必须干净；出现「端点 1/」就是回退');
      // ignore: avoid_print
      print('QAHEALTHY_LABEL=${stages.single}');
    });
  });

  group('候选端点 · 5s 死线与「慢但活着」的相互作用', () {
    test('慢但活着的节点：首轮超时切一次，第二个候选仍超时 → 停止切换（不无限白等）', () async {
      // 复刻线上参数比例：首轮死线 = kConnectTimeout(8s)，回包要 6s 时首轮**能过**；
      // 这里把「首轮死线」压到 100ms、回包 120ms，让首轮必然超时，
      // 用来验证「首轮超时切一次 → 重试轮仍超时则停」这条新语义。
      final rec = _Recorder()
        ..onLatency = (probe) async {
          await Future<void>.delayed(const Duration(milliseconds: 120));
          return const LinkProbeOutcome(ttfbMs: 6000, elapsedMs: 6000);
        };
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: '',
        xray: _FakeXray(),
        pool: _FixedPool(<int>[20000, 20001, 20002]),
        probeFactory: (speed, latency, port) {
          rec.latencyUrls.add(latency);
          return _DeadlineProbe(
            localPort: port,
            speedUrl: speed,
            latencyUrl: latency,
            deadline: const Duration(milliseconds: 100),
            respondAfter: const Duration(milliseconds: 120),
          );
        },
      );

      final sw = Stopwatch()..start();
      final run = await runner.run(
        <String>[for (var i = 0; i < 3; i++) _link('h$i.example', 443)],
        mode: LinkTestMode.latency,
      );
      sw.stop();

      expect(run.results.every((r) => r.state == ProbeState.failed), isTrue,
          reason: '5s 死线下这些「活但慢」的节点仍会失败（口径代价）');
      expect(
          run.results.every((r) => r.failureKind == ProbeFailureKind.timeout),
          isTrue,
          reason: '失败必须归类为超时，否则切换判定会误判');
      expect(rec.latencyUrls.length, 6,
          reason: '3 节点 × 2 次尝试：首轮切一次 + 重试轮停止 = 6；'
              '若是 9 就是「无限切」，若是 3 就是「首轮也不切」');
      // ignore: avoid_print
      print('QASLOWALIVE 3节点×2尝试 = ${sw.elapsedMilliseconds}ms');
    });
  });

  group('候选端点 · 死入站（原先的「fallback 空转」隐患）', () {
    test('本地入站完全不可达 → 归类为建连类 → 候选链会被触发', () async {
      // 历史：一度「死入站被判成超时」→ 按「超时不切」的规则候选链永不触发，
      // fallback 变成空壳。现在首轮死线 = kConnectTimeout，建连失败能先暴露，
      // 于是归成 connect 类 → 正常切换。本用例守这个修复不回退。
      final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = srv.port;
      await srv.close();

      final urls = <String>[];
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: '',
        xray: _FakeXray(),
        pool: _FixedPool(<int>[deadPort]),
        probeFactory: (speed, latency, port) {
          urls.add(latency);
          return LinkProbe(
            speedUrl: speed,
            latencyUrl: latency,
            localPort: port,
            connectTimeout: const Duration(milliseconds: 300),
            latencyTimeout: const Duration(milliseconds: 300),
          );
        },
      );

      final run = await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);
      final r = run.results.single;
      // ignore: avoid_print
      print('QADEADINBOUND error=${r.error} kind=${r.failureKind.name} '
          'attempts=${urls.length}');

      expect(r.state, ProbeState.failed);
      expect(
        urls.length,
        greaterThan(1),
        reason: '候选链必须被触发（>1 次尝试）；只有 1 次就说明又变成「fallback 空转」',
      );
      expect(urls.toSet().length, greaterThan(1), reason: '必须真的换成过别的端点 URL');
    });
  });

  group('候选端点 · 按失败原因决定是否切换（当前语义：首轮超时切一次）', () {
    // 现行判定（lib/data/link_test.dart `_runLatencyStage`）：
    //  · 死线按轮次分：首轮 kConnectTimeout(8s)，重试轮 kLatencyTimeout(5s)；
    //  · 存在超时：
    //      - 混合（超时 + 其它原因）→ 不切；
    //      - 清一色超时 且 attempt==0 且还有候选 → **切一次**（为区分端点坏/线路慢
    //        付一次 attemptTimeout）；
    //      - 清一色超时 但已是重试轮 → 不切（判为线路慢）；
    //  · 无超时：
    //      - 清一色建连类（connect/tlsHandshake）→ 切；
    //      - 否则（含 HTTP 错误/其它）→ 不切。

    test('首轮整批超时 → 切一次（为了区分端点坏还是线路慢），重试轮仍超时 → 停止', () async {
      final logs = <String>[];
      final rec = _Recorder()..onLatency = _timeout;
      final runner = _runner(rec, latencyUrl: _custom, onLog: logs.add);

      await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);

      expect(rec.latencyUrls, <String>[_custom, _ep0],
          reason: '首轮超时允许切一次；第二个候选同样超时 → 不再切（否则无限白等）');
      expect(rec.latencyUrls.contains(_ep1), isFalse,
          reason: '候选 3（gstatic）必须零调用：有界 = 只切一次');
      expect(
        logs.any((l) => l.contains('试下一个候选')),
        isTrue,
        reason: '首轮超时切换必须说明「无法区分端点坏/线路慢，所以试一个」',
      );
      expect(
        logs.any((l) => l.contains('判为线路慢，停止切换端点')),
        isTrue,
        reason: '重试轮仍超时要明确「判为线路慢，停止」',
      );
    });

    test('混合（超时 + 连接失败）→ 不切换（超时已证明部分链路是活的）', () async {
      final logs = <String>[];
      var i = 0;
      final rec = _Recorder()
        ..onLatency =
            (probe) async => (i++ == 0) ? _timeout(probe) : _fail(probe);
      final runner = _runner(rec, latencyUrl: _custom, onLog: logs.add);

      await runner.run(<String>[
        _link('a.example', 443),
        _link('b.example', 443),
      ], mode: LinkTestMode.latency);

      expect(rec.latencyUrls.toSet(), <String>{_custom},
          reason: '混合原因不切：换端点救不了');
      expect(logs.any((l) => l.contains('原因是混合的')), isTrue,
          reason: '日志要说明是混合原因导致不切');
      expect(logs.any((l) => l.contains('试下一个候选')), isFalse);
    });

    test('无超时但类别不全是建连类（连接失败 + HTTP 错误）→ 不切换', () async {
      var i = 0;
      final logs = <String>[];
      final rec = _Recorder()
        ..onLatency = (probe) async => (i++ == 0)
            ? _fail(probe)
            : LinkProbeOutcome.failure('HTTP 500', 20,
                kind: ProbeFailureKind.http);
      final runner = _runner(rec, latencyUrl: _custom, onLog: logs.add);

      await runner.run(<String>[
        _link('a.example', 443),
        _link('b.example', 443),
      ], mode: LinkTestMode.latency);

      expect(rec.latencyUrls.toSet(), <String>{_custom},
          reason: 'HTTP 类失败说明链路是通的，换端点救不了');
      expect(logs.any((l) => l.contains('不足以断定端点不可达')), isTrue,
          reason: '日志必须说明「为什么不够格切换」');
    });

    test('清一色建连类失败 → 切换并走完候选链，日志交代换成谁', () async {
      final logs = <String>[];
      final rec = _Recorder()..onLatency = _fail;
      final runner = _runner(rec, latencyUrl: _custom, onLog: logs.add);

      await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);

      expect(rec.latencyUrls, <String>[_custom, _ep0, _ep1],
          reason: '只有清一色建连类才走完候选链（上限 3 次）');
      expect(
        logs.any((l) => l.contains('拿不到延迟') && l.contains('换下一个候选')),
        isTrue,
        reason: '切换日志必须交代「换了谁、换成谁」',
      );
    });

    test('反向构造：文案写着「超时」但类别是 connect → 仍然切换（证明不读文案）', () async {
      // 若实现比对 error 字符串，这条会红（它看到「超时」就不切）。
      final rec = _Recorder()
        ..onLatency = (probe) async => LinkProbeOutcome.failure(
              kProbeTimeout, // 文案故意写成「超时」
              5,
              kind: ProbeFailureKind.connect, // 但类别是建连类
            );
      final runner = _runner(rec, latencyUrl: _custom);

      await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);

      expect(rec.latencyUrls, <String>[_custom, _ep0, _ep1],
          reason: '判定必须看 failureKind；文案是「超时」也不能影响切换');
    });

    test('反向构造：文案任意但类别是 timeout → 按超时规则处理（不读文案）', () async {
      final rec = _Recorder()
        ..onLatency = (probe) async => LinkProbeOutcome.failure(
              '端点不可达，请检查网络', // 文案看着像端点故障
              5,
              kind: ProbeFailureKind.timeout, // 但类别是超时
            );
      final runner = _runner(rec, latencyUrl: _custom);

      await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);

      expect(rec.latencyUrls, <String>[_custom, _ep0],
          reason: '类别是 timeout → 走「首轮切一次、重试轮停」的超时规则，'
              '而不是像建连类那样走完 3 个候选；这说明判定读的是标志位');
    });
  });

  group('候选端点 · 全超时的可执行提示（C）', () {
    test('整轮一条延迟都没拿到且发生过超时 → 收尾阶段文案带可执行提示', () async {
      final stages = <String>[];
      final rec = _Recorder()..onLatency = _timeout;
      final runner = _runner(rec, latencyUrl: _custom);

      await runner.run(<String>[_link('a.example', 443)],
          mode: LinkTestMode.latency,
          onProgress: (_, stage) => stages.add(stage));

      final last = stages.last;
      expect(last, startsWith('完成'), reason: '收尾文案必须以「完成」开头（后面可能带 · 提示后缀）');
      expect(last, contains('延迟全部超时'), reason: '用户不一定翻日志，结论必须出现在阶段文案上');
      expect(last, contains('更换「延迟测试地址」'), reason: '提示必须可执行：告诉用户下一步点哪里');
      // ignore: avoid_print
      print('QAHINT=$last');
    });

    test('反向对照：有延迟出数时不显示该提示（避免"永远挂一句话"）', () async {
      final stages = <String>[];
      final rec = _Recorder()..onLatency = _ok;
      final runner = _runner(rec);

      await runner.run(<String>[_link('a.example', 443)],
          mode: LinkTestMode.latency,
          onProgress: (_, stage) => stages.add(stage));

      expect(stages.last, '完成', reason: '正常完成时文案应干净，不带提示后缀');
      expect(stages.any((s) => s.contains('延迟全部超时')), isFalse);
    });
  });

  group('候选端点 · 死线按轮次生效（实测，不只看代码）', () {
    test('首轮注入 kConnectTimeout(8s)、重试轮注入 kLatencyTimeout(5s)', () async {
      final rec = _Recorder()..onLatency = _timeout;
      final runner = _runner(rec, latencyUrl: _custom);

      await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);

      expect(rec.probes, hasLength(2), reason: '首轮切一次 + 重试轮停止 = 2 次');
      expect(
        rec.probes[0].observedDeadlines.single,
        kConnectTimeout,
        reason: '首轮死线必须是 kConnectTimeout(8s)：否则建连失败永远先被看门狗吃掉，'
            'fallback 又会变成空壳',
      );
      expect(
        rec.probes[1].observedDeadlines.single,
        kLatencyTimeout,
        reason: '重试轮必须回到 kLatencyTimeout(5s)：不能每轮都付 8s',
      );
      expect(kConnectTimeout, isNot(kLatencyTimeout),
          reason: '两个常量必须不同，否则本用例没有区分力');
      expect(kConnectTimeout.inSeconds, greaterThan(kLatencyTimeout.inSeconds));
    });
  });

  group('候选端点 · 新增控制流的两个风险', () {
    test('R1) 重试必须复用同一个闸门：全流程在飞峰值 ≤ 6', () async {
      final rec = _Recorder()
        ..onLatency = (probe) async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return _fail(probe);
        };
      final runner = _runner(rec, latencyUrl: _custom);

      await runner.run(<String>[
        for (var i = 0; i < 8; i++) _link('h$i.example', 443),
      ], mode: LinkTestMode.latency);

      expect(rec.peak, kLatencyParallel,
          reason: '重跑若不复用 _latGate，切端点瞬间会出现 6+6=12 路并发');
    });

    test('R2) 取消能打断重试循环：第 2 次尝试期间取消 → 第一轮 cancelled，第二轮 done', () async {
      var attemptReached1 = Completer<void>();
      final rec = _Recorder()
        ..onLatency = (probe) async {
          // 第一次尝试立刻全失败 → 触发切换
          if (probe.latencyUrl == _ep0) return _fail(probe);
          // 第二次尝试：挂住，等 runner 的 cancel() 来收尾
          if (!attemptReached1.isCompleted) attemptReached1.complete();
          await probe.cancelSignal;
          return LinkProbeOutcome.cancelledAt(1);
        };
      final runner = _runner(rec, latencyUrl: '');

      final first = runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);
      await attemptReached1.future.timeout(const Duration(seconds: 5));
      expect(rec.latencyUrls, <String>[_ep0, _ep1], reason: '已进入第 2 次尝试');

      await runner.cancel();
      final firstRun = await first;
      expect(firstRun.results.single.state, ProbeState.cancelled,
          reason: '取消必须让重试循环停下来，条目落 cancelled');

      // 第二轮必须能正常跑（闸门在下一轮 reopen）
      rec.onLatency = _ok;
      final second = await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);
      expect(second.results.single.state, ProbeState.done);
    });
  });

  group('模型一致性（timedOut 必须是派生 getter）', () {
    test('timedOut 只能由 failureKind 推出：不可能「超时真但类别是 connect」', () {
      LinkTestResult make(ProbeFailureKind kind) => LinkTestResult(
            link: 'vless://u@a.example:443',
            name: 'a',
            host: 'a.example',
            port: 443,
            failureKind: kind,
          );

      expect(make(ProbeFailureKind.timeout).timedOut, isTrue);
      for (final kind in <ProbeFailureKind>[
        ProbeFailureKind.none,
        ProbeFailureKind.connect,
        ProbeFailureKind.tlsHandshake,
        ProbeFailureKind.http,
        ProbeFailureKind.noData,
        ProbeFailureKind.other,
      ]) {
        expect(make(kind).timedOut, isFalse, reason: '失败类别 $kind 不该被当成超时');
      }
      // 派生 getter 的意义：两个字段不可能各自赋值后自相矛盾
      expect(make(ProbeFailureKind.connect).timedOut, isFalse);
      expect(
          make(ProbeFailureKind.connect).failureKind, ProbeFailureKind.connect);
    });

    test('copyWith 能把 failureKind 显式复位（避免「error 清了但类别还留着」）', () {
      const timedOutRow = LinkTestResult(
        link: 'vless://u@b.example:443',
        name: 'b',
        host: 'b.example',
        port: 443,
        error: kProbeTimeout,
        state: ProbeState.failed,
        failureKind: ProbeFailureKind.timeout,
      );
      expect(timedOutRow.timedOut, isTrue);

      final reset = timedOutRow.copyWith(
        failureKind: ProbeFailureKind.none,
        state: ProbeState.pending,
      );
      expect(reset.timedOut, isFalse,
          reason: '重试前清失败状态时，类别必须能一起复位，否则会带着旧的 timeout 参与判定');
      expect(reset.failureKind, ProbeFailureKind.none);
    });

    test('ProbeFailureKind.isConnectLike 只认 connect 与 tlsHandshake', () {
      expect(ProbeFailureKind.connect.isConnectLike, isTrue);
      expect(ProbeFailureKind.tlsHandshake.isConnectLike, isTrue);
      for (final kind in <ProbeFailureKind>[
        ProbeFailureKind.none,
        ProbeFailureKind.timeout,
        ProbeFailureKind.http,
        ProbeFailureKind.noData,
        ProbeFailureKind.other,
      ]) {
        expect(kind.isConnectLike, isFalse, reason: '$kind 不该被当成建连类');
      }
    });
  });

  group('候选端点 · 不许碰到的三条旧语义', () {
    test('speedMib == null 仍是「未测」，不退化成 0.0', () async {
      final rec = _Recorder()..onLatency = _ok;
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: '',
        xray: _FakeXray(),
        pool: _FixedPool(<int>[20000]),
        probeFactory: (speed, latency, port) => _WarmupShortProbe(
            speedUrl: speed, latencyUrl: latency, localPort: port),
      );

      final run = await runner.run(<String>[_link('a.example', 443)]);
      final result = run.results.single;

      expect(result.speedMib, isNull, reason: '预热未完成 = 未测，绝不能写 0.0');
      expect(result.error, kProbeWarmupIncomplete);
      expect(result.hasSpeed, isFalse);
      expect(rec.probes, isEmpty, reason: '本用例用的是自己的工厂，rec 不该被调用');
    });

    test('cancelled 与 failed 不混用（重试失败后仍是 failed，不是 cancelled）', () async {
      final rec = _Recorder()..onLatency = _fail;
      final runner = _runner(rec, latencyUrl: _custom);

      final run = await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);

      final result = run.results.single;
      expect(result.state, ProbeState.failed);
      expect(result.error, isNotNull);
      expect(result.ok, isFalse);
    });

    test('速度阶段仍然跟随跳转（302 → 200 大 body 能测出速度）', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final resp = req.response;
        if (req.uri.path.contains('300.zip')) {
          resp.statusCode = HttpStatus.found;
          resp.headers
              .set(HttpHeaders.locationHeader, 'http://cdn.test/blob.bin');
          resp.contentLength = 0;
          await resp.close();
          return;
        }
        const total = kWarmupBytes + 2 * 1024 * 1024;
        resp.statusCode = 200;
        resp.contentLength = total;
        resp.add(List<int>.filled(total, 0x41));
        await resp.close();
      });
      addTearDown(() => server.close(force: true));

      final probe = LinkProbe(
        speedUrl: _speedUrl,
        latencyUrl: '',
        localPort: server.port,
      );
      final outcome = await probe.speed();

      expect(outcome.error, isNull,
          reason: '大文件端点 302 到 CDN 是常态；关掉 followRedirects 会让测速全挂');
      expect(outcome.speedMib, isNotNull);
      expect(outcome.timings!.redirects, 1);
    });
  });
}

/// 速度阶段「预热未完成」的探针：延迟成功，速度返回 null + 预热文案。
class _WarmupShortProbe extends LinkProbe {
  _WarmupShortProbe({
    required super.localPort,
    required super.speedUrl,
    required super.latencyUrl,
  });

  @override
  Future<LinkProbeOutcome> latency() async =>
      const LinkProbeOutcome(ttfbMs: 30, elapsedMs: 32);

  @override
  Future<LinkProbeOutcome> speed() async => const LinkProbeOutcome(
        ttfbMs: 40,
        error: kProbeWarmupIncomplete,
        elapsedMs: 3000,
      );
}

/// 带「死线」语义的假探针：`respondAfter` 才回首字节，但 [deadline] 先到，
/// 于是这个探测必然以「超时」收尾 —— 模拟 kLatencyTimeout=5s 打断 6s 的慢节点。
class _DeadlineProbe extends LinkProbe {
  _DeadlineProbe({
    required super.localPort,
    required super.speedUrl,
    required super.latencyUrl,
    required this.deadline,
    required this.respondAfter,
  });

  final Duration deadline;
  final Duration respondAfter;

  @override
  Future<LinkProbeOutcome> latency() {
    final real = Future<LinkProbeOutcome>.delayed(
      respondAfter,
      () => LinkProbeOutcome(
        ttfbMs: respondAfter.inMilliseconds,
        elapsedMs: respondAfter.inMilliseconds,
      ),
    );
    final timeout = Future<LinkProbeOutcome>.delayed(
      deadline,
      () => LinkProbeOutcome.failure(
        kProbeTimeout,
        deadline.inMilliseconds,
        kind: ProbeFailureKind.timeout,
      ),
    );
    return Future.any(<Future<LinkProbeOutcome>>[real, timeout]);
  }
}
