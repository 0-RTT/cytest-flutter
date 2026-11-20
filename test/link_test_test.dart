import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/core/idna.dart';
import 'package:cytest/core/semaphore.dart';
import 'package:cytest/data/link_probe.dart';
import 'package:cytest/data/link_test.dart';
import 'package:cytest/data/link_test_store.dart';
import 'package:cytest/data/vless.dart';
import 'package:cytest/data/xray.dart';
import 'package:cytest/state/app_state.dart';

/// 单测里延迟与速度都指向同一个本地服务：`http://` 目标走 absolute-form，
/// fake 入站不需要 CONNECT/TLS 就能扮演「本机 xray 入站」。
const String _testUrl = 'http://speed.test/300.zip';

/// 造一条最小可用 vless（只填 runner/Vless.tryParse 会读的字段）。
String _link(String host, int port, {String? name}) =>
    'vless://uuid-$port@$host:$port'
    '?type=ws&security=tls&sni=$host&path=%2Fws'
    '${name == null ? '' : '#${Uri.encodeComponent(name)}'}';

/// 可控的批量启动器：替代真 xray 进程（真机二进制在桌面跑不了）。
class _FakeXray implements BatchXray {
  _FakeXray({this.startError, XrayMode initialMode = XrayMode.none})
      : mode = initialMode;

  @override
  XrayMode mode;

  /// 非 null 时 startBatch 直接返回该错误串（模拟端口未就绪 / 进程退出）。
  String? startError;

  int startCalls = 0;
  int stopCalls = 0;
  List<(Vless, int)> lastNodes = const <(Vless, int)>[];

  @override
  Future<String?> startBatch(List<(Vless, int)> nodes) async {
    startCalls++;
    // 真实 XrayProc.startBatch 第一行就是 await stop()（串行互斥），
    // fake 必须一样：否则「失败路径上代理也已被杀」这个事实在测试里消失，
    // K4 的失败路径就永远测不出来。
    await stop();
    lastNodes = nodes;
    final error = startError;
    if (error != null) return error;
    mode = XrayMode.batch;
    return null;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    mode = XrayMode.none;
  }
}

/// 固定端口的池子：把「本机 HttpServer 端口」当成 xray 入站口。
class _FixedPool extends PortPool {
  _FixedPool(this.ports);

  final List<int> ports;

  @override
  Future<PortPick> pick(int n) async {
    final take = ports.take(n).toList(growable: false);
    return PortPick(ports: take, missing: n - take.length);
  }
}

/// 起一个「扮成本机入站口」的 HTTP 服务；[bodyBytes] 字节、[delayMs] 后才吐。
Future<HttpServer> _serve({int bodyBytes = 4096, int delayMs = 0}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    if (delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
    }
    final response = request.response;
    response.contentLength = bodyBytes;
    if (bodyBytes > 0) {
      response.add(List<int>.filled(bodyBytes, 0x41));
    }
    await response.close();
  });
  return server;
}

/// 起一个「接了但永不响应」的服务（验看门狗与取消）。
Future<HttpServer> _hang() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((_) {
    // 故意不响应：连接保持打开，直到客户端/服务端被 close(force: true)
  });
  return server;
}

/// 按「探测到的延迟端点 URL」决定结果的探测（模拟端点不可达 / 可通）。
///
/// 用它就能在不碰网络的前提下验「换端点重跑」：同一个探针类，换个 URL 就换个
/// 行为，和真实世界里「cp.cloudflare.com 挂了但 gstatic 是通的」同构。
class _UrlScriptedProbe extends LinkProbe {
  _UrlScriptedProbe({
    required super.speedUrl,
    required super.latencyUrl,
    required super.localPort,
    required this.onLatency,
    required this.inFlight,
  });

  /// 延迟结果由「这次打的是哪个 URL」决定。
  final Future<LinkProbeOutcome> Function(String url) onLatency;

  /// 在飞计数（验「重试路径也不许超过 6 路并发」）。
  final void Function(int delta) inFlight;

  @override
  Future<LinkProbeOutcome> latency() async {
    inFlight(1);
    try {
      return await onLatency(latencyUrl);
    } finally {
      inFlight(-1);
    }
  }

  @override
  Future<LinkProbeOutcome> speed() async =>
      const LinkProbeOutcome(ttfbMs: 20, speedMib: 1.0, elapsedMs: 100);
}

/// 可精确卡住 `stop()` 的批量启动器。
///
/// 用途：`LinkTestRunner.cancel()` 最后一步是 `await _xray.stop()`，
/// 把这一步挂住就能**确定地**制造「用户已点取消、收尾还没回来」这个窗口，
/// 不必用 sleep 去赌时序。语义与真实现一致：`startBatch` 第一行就 `stop()`。
class _GatedXray implements BatchXray {
  @override
  XrayMode mode = XrayMode.none;

  /// 非 null 时，下一次 `stop()` 会等它完成（消费后自动置回 null）。
  Completer<void>? gate;

  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<String?> startBatch(List<(Vless, int)> nodes) async {
    startCalls++;
    await stop();
    mode = XrayMode.batch;
    return null;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    mode = XrayMode.none;
    final pending = gate;
    if (pending != null) {
      gate = null;
      await pending.future;
    }
  }
}

/// 只在 [release]（或被 [cancel]）之后才返回的探测。
///
/// 同样是为了去掉 sleep：测试可以确定「探测正在跑、还没出结果」。
class _GatedProbe extends LinkProbe {
  _GatedProbe({required super.localPort});

  final Completer<void> _gate = Completer<void>();

  int latencyCalls = 0;

  /// 放行：让在途的 latency() 立刻返回。
  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<LinkProbeOutcome> latency() async {
    latencyCalls++;
    await _gate.future;
    return const LinkProbeOutcome(ttfbMs: 5, elapsedMs: 5);
  }

  @override
  void cancel() {
    super.cancel();
    // 真实的 cancel() 会让在途请求立刻结束；这里等价成放行，避免测试挂死。
    release();
  }
}

/// 造一个「整批延迟失败」用的 runner：延迟端点固定为首选
/// `http://first.test/generate_204`，每条探测的结果由 [onLatency] 按
/// (端点 URL, 入站端口) 决定。
///
/// 为什么要把端口透给假件：同一条候选端点上，「a 超时、b 连接失败」这种混合
/// 整批正是本次判定的关键场景，只按 URL 分派就表达不出来。
LinkTestRunner _batchRunner({
  required Future<LinkProbeOutcome> Function(String url, int port) onLatency,
  required List<String> seen,
  required List<int> ports,
  void Function(String message)? onLog,
}) =>
    LinkTestRunner(
      xray: _FakeXray(),
      speedUrl: 'http://speed.test/300.zip',
      latencyUrl: 'http://first.test/generate_204',
      pool: _FixedPool(ports),
      onLog: onLog,
      probeFactory: (speedUrl, latencyUrl, port) {
        seen.add(latencyUrl);
        return _UrlScriptedProbe(
          speedUrl: speedUrl,
          latencyUrl: latencyUrl,
          localPort: port,
          inFlight: (_) {},
          onLatency: (url) => onLatency(url, port),
        );
      },
    );

/// 「5s 死线到点」这种失败（结构化类别是 timeout，不是靠文案）。
LinkProbeOutcome _timeoutOutcome() => LinkProbeOutcome.failure(
      kProbeTimeout,
      kLatencyTimeout.inMilliseconds,
      kind: ProbeFailureKind.timeout,
    );

void main() {
  group('idnaToAscii · RFC 3492 官方样例（K1 硬要求 ≥5 条）', () {
    test('münchen.de → xn--mnchen-3ya.de（德语变音符）', () {
      expect(idnaToAscii('münchen.de'), 'xn--mnchen-3ya.de');
    });

    test('bücher.example → xn--bcher-kva.example（混合 ASCII label）', () {
      expect(idnaToAscii('bücher.example'), 'xn--bcher-kva.example');
    });

    test('纯非 ASCII 单 label：例 → xn--fsq（基本码点为空，靠 delta 编码）', () {
      expect(idnaToAscii('例'), 'xn--fsq');
    });

    test('多 label 全非 ASCII：пример.рф → xn--e1afmkfd.xn--p1ai（西里尔）', () {
      expect(idnaToAscii('пример.рф'), 'xn--e1afmkfd.xn--p1ai');
    });

    test('中国 → xn--fiqs8s（RFC 3492 §7.1 Chinese 样例的常用子集）', () {
      expect(idnaToAscii('中国'), 'xn--fiqs8s');
    });

    test('日本語 → xn--wgv71a119e（CJK 混排多码点）', () {
      expect(idnaToAscii('日本語'), 'xn--wgv71a119e');
    });

    test('例え → xn--r8jz45g（与 .NET IdnMapping 逐条一致）', () {
      expect(idnaToAscii('例え'), 'xn--r8jz45g');
    });

    test('Bücher.Example → xn--bcher-kva.Example（只折叠含非 ASCII 的 label）', () {
      // 注意：**.NET 会输出 xn--bcher-kva.example**（它把纯 ASCII label 也小写化）。
      // K1 要求「全 ASCII 原样返回、大小写不丢」，所以我们**有意**与 .NET 不同。
      // 后人若拿 .NET 当 oracle，不要把这条当 bug 修。
      expect(idnaToAscii('Bücher.Example'), 'xn--bcher-kva.Example');
    });

    test('已全 ASCII 的域名原样返回，大小写不丢（K1 要求）', () {
      expect(idnaToAscii('Example.COM'), 'Example.COM');
      expect(idnaToAscii('a-b.c'), 'a-b.c');
    });

    test('非 ASCII label 先小写折叠：München → xn--mnchen-3ya', () {
      expect(idnaToAscii('München.DE'), 'xn--mnchen-3ya.DE');
    });

    test('结尾的点（FQDN 写法）保留', () {
      expect(idnaToAscii('münchen.de.'), 'xn--mnchen-3ya.de.');
    });

    test('两端空白被 trim（用户从浏览器复制常带空格）', () {
      expect(idnaToAscii('  bücher.example  '), 'xn--bcher-kva.example');
    });
  });

  group('idnaToAscii · 异常路径（显式抛，绝不静默降级）', () {
    test('空域名抛 UnsupportedIdnException', () {
      expect(() => idnaToAscii(''), throwsA(isA<UnsupportedIdnException>()));
      expect(() => idnaToAscii('   '), throwsA(isA<UnsupportedIdnException>()));
      expect(() => idnaToAscii('.'), throwsA(isA<UnsupportedIdnException>()));
    });

    test('Emoji 抛 UnsupportedIdnException，且文案指出字符', () {
      expect(
        () => idnaToAscii('😀.example'),
        throwsA(
          isA<UnsupportedIdnException>()
              .having((e) => e.message, 'message', contains('不支持的字符'))
              .having((e) => e.codePoint, 'codePoint', 0x1F600),
        ),
      );
    });

    test('组合附加符（e + U+0301）抛异常，不做静默归一化', () {
      expect(
        () => idnaToAscii('e\u0301.example'),
        throwsA(isA<UnsupportedIdnException>()),
      );
    });

    test('单 label 超 63 字节抛异常', () {
      final longLabel = 'ü' * 62; // punycode 后必然 > 63
      expect(
        () => idnaToAscii(longLabel),
        throwsA(isA<UnsupportedIdnException>()),
      );
    });

    test('中间有空 label（a..b）抛异常', () {
      expect(
        () => idnaToAscii('a..b'),
        throwsA(isA<UnsupportedIdnException>()),
      );
    });

    test('全角符号 / 空白等非字母数字抛异常', () {
      // 全角 ａ 是 U+FF41，属于「形似字母的符号」，IDNA2008 不接受
      expect(
        () => idnaToAscii('ａｂｃ.example'),
        throwsA(isA<UnsupportedIdnException>()),
      );
    });
  });

  group('probeUri · 端到端 ASCII 化（K1 ②）', () {
    test('默认测速地址的主机名以 xn-- 开头且全 ASCII', () {
      final uri = probeUri('https://е.eu.org/300.zip');

      expect(uri.host.startsWith('xn--'), isTrue, reason: 'host=${uri.host}');
      expect(RegExp(r'^[\x00-\x7F]+$').hasMatch(uri.host), isTrue);
      expect(uri.host, 'xn--e1a.eu.org');
      expect(uri.scheme, 'https');
      expect(uri.path, '/300.zip');
    });

    test('http 也能过（协议白名单只认 http/https）', () {
      expect(probeUri('http://е.eu.org/').host, 'xn--e1a.eu.org');
    });

    test('本来就 ASCII 的地址原样返回，路径与 query 不受影响', () {
      final uri = probeUri('https://speed.example.com/a/b.zip?x=1&y=%20');

      expect(uri.host, 'speed.example.com');
      expect(uri.path, '/a/b.zip');
      expect(uri.query, 'x=1&y=%20');
    });

    test('非 http 协议抛 FormatException，文案含「必须以 http」', () {
      expect(
        () => probeUri('ftp://example.com/x'),
        throwsA(
          isA<FormatException>()
              .having((e) => e.message, 'message', contains('必须以 http')),
        ),
      );
    });

    test('空串 / 无 host / 无法解析都抛 FormatException', () {
      expect(() => probeUri(''), throwsA(isA<FormatException>()));
      expect(() => probeUri('   '), throwsA(isA<FormatException>()));
      expect(() => probeUri('not a url'), throwsA(isA<FormatException>()));
      expect(() => probeUri('/just/a/path'), throwsA(isA<FormatException>()));
    });

    test('含 Emoji 的主机名抛 UnsupportedIdnException，且不返回任何 URI', () {
      expect(
        () => probeUri('https://😀.example/300.zip'),
        throwsA(isA<UnsupportedIdnException>()),
      );
    });

    test('端口保留（http://е.eu.org:8443/x）', () {
      final uri = probeUri('http://е.eu.org:8443/x');

      expect(uri.host, 'xn--e1a.eu.org');
      expect(uri.port, 8443);
    });
  });

  // -------------------------------------------------------------------------
  // Semaphore（T01 交付物）：6 路延迟闸门 / 2 路测速闸门 / 取消时的 drain
  // -------------------------------------------------------------------------
  group('Semaphore 并发闸门', () {
    test('许可用尽后 acquire 排队，release 立即放行下一个（FIFO）', () async {
      final gate = Semaphore(2);
      await gate.acquire();
      await gate.acquire();
      expect(gate.permits, 0);

      var thirdStarted = false;
      final third = gate.acquire().then((_) => thirdStarted = true);
      // 让事件循环跑一轮，确认第三个确实被挡住了
      await Future<void>.delayed(Duration.zero);
      expect(thirdStarted, isFalse);
      expect(gate.waiting, 1);

      gate.release();
      await third;
      expect(thirdStarted, isTrue);
    });

    test('withPermit 在任务抛异常时也归还许可（否则闸门会被永久卡死）', () async {
      final gate = Semaphore(1);

      await expectLater(
        gate.withPermit<void>(() async => throw StateError('探测失败')),
        throwsA(isA<StateError>()),
      );

      expect(gate.permits, 1, reason: 'finally 里必须 release');
    });

    test('并发上限真的生效：6 路闸门下峰值并发不超过 6', () async {
      final gate = Semaphore(6);
      var running = 0;
      var peak = 0;

      Future<void> task() => gate.withPermit(() async {
            running++;
            peak = running > peak ? running : peak;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            running--;
          });

      await Future.wait(List<Future<void>>.generate(20, (_) => task()));

      expect(peak, 6, reason: '20 个任务、6 个许可 → 峰值必须是 6');
      expect(running, 0);
      expect(gate.permits, 6, reason: '全部结束后许可必须完整归还');
    });

    test('drain：等待者立刻以 CancelledException 失败，之后 acquire 也直接失败', () async {
      final gate = Semaphore(1);
      await gate.acquire();

      final waiter = gate.acquire();
      gate.drain();

      await expectLater(waiter, throwsA(isA<CancelledException>()));
      await expectLater(gate.acquire(), throwsA(isA<CancelledException>()));
      expect(gate.drained, isTrue);
    });

    test('drain 幂等：重复调用无副作用', () async {
      final gate = Semaphore(2);

      gate.drain();
      gate.drain();

      await expectLater(gate.acquire(), throwsA(isA<CancelledException>()));
    });

    test('drain 后 release 不会让在途任务「复活」闸门', () async {
      final gate = Semaphore(1);
      await gate.acquire();
      gate.drain();
      gate.release();

      await expectLater(gate.acquire(), throwsA(isA<CancelledException>()));
    });

    test('reopen 允许下一轮测试会话复用同一个闸门', () async {
      final gate = Semaphore(2);
      gate.drain();
      gate.reopen();

      await gate.acquire();
      expect(gate.permits, 1);
    });

    test('多个等待者严格按 FIFO 顺序放行（慢链不能插队）', () async {
      final gate = Semaphore(1);
      await gate.acquire();

      final order = <int>[];
      final waiters = <Future<void>>[
        for (var i = 0; i < 3; i++) gate.acquire().then((_) => order.add(i)),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(gate.waiting, 3);

      // 逐个放行：每次 release 应当交给队首
      gate.release();
      await waiters[0];
      gate.release();
      await waiters[1];
      gate.release();
      await waiters[2];

      expect(order, <int>[0, 1, 2], reason: 'FIFO：先排队的先拿到许可');
      expect(gate.permits, 0, reason: '最后一个许可是直接转交给等待者，不回到池子里');
    });

    test('drain 时多个等待者全部以 CancelledException 失败（不泄漏 Completer）', () async {
      final gate = Semaphore(1);
      await gate.acquire();

      final waiters = <Future<void>>[
        for (var i = 0; i < 4; i++) gate.acquire(),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(gate.waiting, 4);

      gate.drain();

      for (final waiter in waiters) {
        await expectLater(waiter, throwsA(isA<CancelledException>()));
      }
      expect(gate.waiting, 0, reason: '等待队列必须被清空，否则会留下永不完成的 Future');
    });
  });

  // -------------------------------------------------------------------------
  // T03：模型 / 端口池 / 编排器
  // -------------------------------------------------------------------------
  group('LinkTestResult / LinkTestRun 模型', () {
    test('未测 ≠ 0：speedMib 为 null 时 hasSpeed 为假', () {
      const notMeasured = LinkTestResult(
        link: 'vless://a',
        name: 'a',
        host: '1.1.1.1',
        port: 443,
        latencyMs: 120,
        state: ProbeState.done,
      );
      const measured = LinkTestResult(
        link: 'vless://b',
        name: 'b',
        host: '2.2.2.2',
        port: 443,
        latencyMs: 120,
        speedMib: 8.5,
        state: ProbeState.done,
      );

      expect(notMeasured.ok, isTrue);
      expect(notMeasured.latencyKnown, isTrue);
      expect(notMeasured.hasSpeed, isFalse);
      expect(notMeasured.speedMib, isNull);
      expect(measured.hasSpeed, isTrue);
    });

    test('cancelled 不算可用（ok 为假），即使没有 error', () {
      const cancelled = LinkTestResult(
        link: 'vless://c',
        name: 'c',
        host: '3.3.3.3',
        port: 443,
        state: ProbeState.cancelled,
      );

      expect(cancelled.error, isNull);
      expect(cancelled.ok, isFalse);
    });

    test('okCount / fastest 只统计可用且有速度的条目', () {
      const run = LinkTestRun(
        id: '1',
        createdAt: 1,
        mode: LinkTestMode.auto,
        results: <LinkTestResult>[
          LinkTestResult(
            link: 'a',
            name: 'a',
            host: '1.1.1.1',
            port: 1,
            speedMib: 3.2,
            state: ProbeState.done,
          ),
          LinkTestResult(
            link: 'b',
            name: 'b',
            host: '2.2.2.2',
            port: 2,
            speedMib: 9.9,
            state: ProbeState.done,
          ),
          LinkTestResult(
            link: 'c',
            name: 'c',
            host: '3.3.3.3',
            port: 3,
            error: '超时',
            state: ProbeState.failed,
          ),
        ],
      );

      expect(run.okCount, 2);
      expect(run.fastest, closeTo(9.9, 0.001));
    });

    test('JSON 往返保真：speedMib 的 null 不能被写成 0', () {
      const original = LinkTestResult(
        link: 'vless://x',
        name: 'x',
        host: '1.1.1.1',
        port: 443,
        latencyMs: 88,
        state: ProbeState.done,
      );

      final restored = LinkTestResult.fromJson(original.toJson());

      expect(restored.speedMib, isNull);
      expect(restored.latencyMs, 88);
      expect(restored.state, ProbeState.done);
    });

    test('timedOut 标志随 JSON 往返保真，且不污染 ok / hasSpeed 语义', () {
      final timedOutResult = LinkTestResult(
        link: 'vless://t',
        name: 't',
        host: '1.1.1.1',
        port: 443,
        error: kProbeTimeout,
        elapsedMs: kLatencyTimeout.inMilliseconds,
        state: ProbeState.failed,
        failureKind: ProbeFailureKind.timeout,
      );

      final restored = LinkTestResult.fromJson(timedOutResult.toJson());
      expect(restored.timedOut, isTrue);
      expect(restored.error, kProbeTimeout);
      expect(restored.ok, isFalse, reason: '超时必然不可用（error 非 null）');
      expect(restored.hasSpeed, isFalse);
      expect(restored.speedMib, isNull, reason: '未测 ≠ 0');

      // copyWith 可以用 `ProbeFailureKind.none` 显式复位（与 error 的 `??` 限制不同）。
      expect(
        restored.copyWith(failureKind: ProbeFailureKind.none).timedOut,
        isFalse,
      );
      expect(restored.copyWith(elapsedMs: 1).timedOut, isTrue,
          reason: '不改 timedOut 时必须原样保留');

      // 旧历史文件两个键都没有 → 类别缺省 none，读盘不能抛。
      final legacy = LinkTestResult.fromJson(
        restored.toJson()
          ..remove('timedOut')
          ..remove('failureKind'),
      );
      expect(legacy.timedOut, isFalse);
      expect(legacy.error, kProbeTimeout);
    });
  });

  group('PortPool / bindPortsToNodes（D3：不再假成功）', () {
    test('被占用的端口会被跳过（真 bind 验证空闲）', () async {
      final held = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => held.close());

      final picked = await const PortPool(base: 20000, span: 500).pick(3);

      expect(picked.ports.length, 3);
      expect(picked.ports.contains(held.port), isFalse);
      expect(picked.enough, isTrue);
    });

    test('端口不够时 missing > 0，绝不兜底返回一个被占用的端口', () async {
      // 跨度设为 3，只要占住这 3 个口就一定不够
      const pool = PortPool(base: 21000, span: 3);
      final held = <ServerSocket>[];
      addTearDown(() async {
        for (final socket in held) {
          await socket.close();
        }
      });
      for (var p = 21000; p < 21003; p++) {
        try {
          held.add(await ServerSocket.bind(InternetAddress.loopbackIPv4, p));
        } on Object {
          // 该端口可能已被系统占用，跳过即可
        }
      }

      final picked = await pool.pick(3);

      expect(picked.enough, isFalse);
      expect(picked.missing, greaterThan(0));
      expect(picked.ports.length + picked.missing, 3);
    });

    test('pick(0) 直接返回空', () async {
      final picked = await const PortPool().pick(0);

      expect(picked.ports, isEmpty);
      expect(picked.missing, 0);
    });

    test('bindPortsToNodes 严格按顺序绑定（端口 ↔ 节点索引是唯一关联键）', () {
      final a = Vless.tryParse(_link('a.example', 443))!;
      final b = Vless.tryParse(_link('b.example', 8443))!;

      final bound = bindPortsToNodes(<Vless>[a, b], <int>[20000, 20001]);

      expect(bound.length, 2);
      expect(bound[0].$1.host, 'a.example');
      expect(bound[0].$2, 20000);
      expect(bound[1].$1.host, 'b.example');
      expect(bound[1].$2, 20001);
    });

    test('bindPortsToNodes 长度不一致直接抛（防止静默串行）', () {
      final a = Vless.tryParse(_link('a.example', 443))!;

      expect(
        () => bindPortsToNodes(<Vless>[a], <int>[20000, 20001]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('LinkTestRunner（注入 fake xray + 本地 HttpServer 当入站口）', () {
    test('latency 模式：延迟取真实 TTFB，速度保持「未测」', () async {
      final server = await _serve(delayMs: 300);
      addTearDown(() => server.close(force: true));
      final xray = _FakeXray();
      final saved = <LinkTestRun>[];
      final runner = LinkTestRunner(
        speedUrl: _testUrl,
        latencyUrl: _testUrl,
        xray: xray,
        pool: _FixedPool(<int>[server.port]),
        saver: (run) async => saved.add(run),
      );

      final run = await runner.run(
        <String>[_link('a.example', 443)],
        mode: LinkTestMode.latency,
      );

      expect(run.results.length, 1);
      final result = run.results.single;
      expect(result.error, isNull);
      expect(result.latencyMs, greaterThanOrEqualTo(250));
      expect(result.speedMib, isNull, reason: '只测延迟 → 速度必须是未测');
      expect(result.state, ProbeState.done);
      expect(xray.startCalls, 1);
      expect(xray.stopCalls, greaterThanOrEqualTo(1), reason: '收尾必须停批量进程');
      expect(saved.length, 1, reason: '正常完成要落盘');
    });

    test('auto 模式：有响应的条目会进速度阶段并测出速度', () async {
      final server = await _serve(bodyBytes: 2 * 1024 * 1024);
      addTearDown(() => server.close(force: true));
      final runner = LinkTestRunner(
        speedUrl: _testUrl,
        latencyUrl: _testUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[server.port]),
      );

      final run = await runner.run(<String>[_link('a.example', 443)]);

      final result = run.results.single;
      expect(result.error, isNull);
      expect(result.latencyKnown, isTrue);
      expect(result.speedMib, isNotNull);
      expect(result.hasSpeed, isTrue);
    });

    test('auto 模式：速度阶段不得覆盖延迟阶段的 TTFB（Bug B 第二条根因）', () async {
      // 一个按路径分流的本地入站：
      // - `generate_204` → 立刻 204（= 延迟端点，口径干净）
      // - 其余（300.zip）→ 先压 400ms 再吐 body（= 大文件端点被服务端缓冲推迟，
      //   真实线路里还会叠加一次跨主机跳转的建链）
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final response = request.response;
        if (request.uri.path.contains('generate_204')) {
          response.statusCode = HttpStatus.noContent;
          await response.close();
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
        const total = kWarmupBytes + 2 * 1024 * 1024;
        response.statusCode = 200;
        response.contentLength = total;
        response.add(List<int>.filled(total, 0x41));
        await response.close();
      });
      addTearDown(() => server.close(force: true));

      final runner = LinkTestRunner(
        speedUrl: _testUrl,
        latencyUrl: 'http://speed.test/generate_204',
        xray: _FakeXray(),
        pool: _FixedPool(<int>[server.port]),
      );

      final run = await runner.run(<String>[_link('a.example', 443)]);

      final result = run.results.single;
      expect(result.state, ProbeState.done);
      expect(result.speedMib, isNotNull, reason: '速度阶段本身要能出数');
      expect(
        result.latencyMs,
        lessThan(300),
        reason: '延迟读数必须是延迟阶段（小端点）的数；'
            '若被速度阶段的 TTFB（≥400ms，含服务端缓冲/跳转）覆盖，这里就会超 400',
      );
    });

    test('speed 模式（没测过延迟）：速度阶段的 TTFB 兼作延迟', () async {
      final server =
          await _serve(delayMs: 10, bodyBytes: kWarmupBytes + 2 * 1024 * 1024);
      addTearDown(() => server.close(force: true));
      final runner = LinkTestRunner(
        speedUrl: _testUrl,
        latencyUrl: _testUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[server.port]),
      );

      final run = await runner.run(
        <String>[_link('a.example', 443)],
        mode: LinkTestMode.speed,
      );

      final result = run.results.single;
      expect(result.speedMib, isNotNull);
      expect(
        result.latencyKnown,
        isTrue,
        reason: 'speed-only 模式下延迟只能由速度阶段提供，不能因为「保留延迟」而变成未知',
      );
    });

    test('auto 模式：死链只有延迟阶段，不进速度阶段（省 3s 空转）', () async {
      // 拿一个「一定没人监听」的端口：bind 后立刻关掉
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();

      var probeCalls = 0;
      final runner = LinkTestRunner(
        speedUrl: _testUrl,
        latencyUrl: _testUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[deadPort]),
        probeFactory: (speedUrl, latencyUrl, port) {
          probeCalls++;
          return LinkProbe(
            speedUrl: speedUrl,
            latencyUrl: latencyUrl,
            localPort: port,
            latencyTimeout: const Duration(seconds: 2),
          );
        },
      );

      final run = await runner.run(<String>[_link('dead.example', 443)]);

      expect(run.results.single.error, isNotNull);
      expect(run.results.single.state, ProbeState.failed);
      expect(run.results.single.speedMib, isNull, reason: '死链不进速度阶段');
      // 延迟阶段会按候选端点链重试，本用例 latencyUrl 与 speedUrl 相同，
      // 去重后 = [speedUrl, cp.cloudflare.com, gstatic] → 上限 3 次。
      //
      // ⚠️ 这里**不能**断言「恰好 N 次」：连一个没人监听的回环端口，在本机实测
      // 走的是看门狗死线而不是立即 ECONNREFUSED，也就是 `failureKind == timeout`
      // 而非 connect —— 而超时触发几次切换取决于「首轮是否允许切一次」的口径
      // （见 `LinkTestRunner._runLatencyStage` 的 timedOutCount 分支），口径一变
      // 次数就变。这条用例真正要守的是「死链不许进速度阶段」：一旦跑进速度阶段，
      // probeCalls 会变成 延迟尝试次数 + 1，用上界即可把它抓出来。
      expect(probeCalls, lessThanOrEqualTo(kLatencyMaxAttempts),
          reason: '死链最多在候选端点间重试到上限，但不该进速度阶段');
    });

    test('K5 正控制：门禁通过时探针**确实被调用**（证明计数器会动）', () async {
      final server = await _serve(delayMs: 10);
      addTearDown(() => server.close(force: true));
      var probeCalls = 0;
      final runner = LinkTestRunner(
        speedUrl: _testUrl,
        latencyUrl: _testUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[server.port]),
        probeFactory: (speedUrl, latencyUrl, port) {
          probeCalls++;
          return LinkProbe(
              speedUrl: speedUrl, latencyUrl: latencyUrl, localPort: port);
        },
      );

      final run = await runner.run(
        <String>[_link('a.example', 443)],
        mode: LinkTestMode.latency,
      );

      // 这一条是「负控制有意义」的前提：计数器真的会随成功路径 +1
      expect(probeCalls, greaterThan(0), reason: '门禁通过必须真的发探测');
      expect(probeCalls, 1);
      expect(run.results.single.latencyKnown, isTrue);
    });

    test('K5 负控制：批量启动失败 → 全部标失败、零探测、不落盘、透出尾部日志', () async {
      const tail = 'failed to bind 20000';
      var probeCalls = 0;
      final saved = <LinkTestRun>[];
      final runner = LinkTestRunner(
        speedUrl: _testUrl,
        latencyUrl: _testUrl,
        xray: _FakeXray(startError: tail),
        pool: _FixedPool(<int>[20000, 20001]),
        saver: (run) async => saved.add(run),
        probeFactory: (speedUrl, latencyUrl, port) {
          probeCalls++;
          return LinkProbe(
              speedUrl: speedUrl, latencyUrl: latencyUrl, localPort: port);
        },
      );

      final run = await runner.run(<String>[
        _link('a.example', 443),
        _link('b.example', 8443),
      ]);

      expect(probeCalls, 0, reason: '端口门禁不过，一条探测都不许发');
      expect(run.results.length, 2);
      for (final result in run.results) {
        expect(result.state, ProbeState.failed);
        expect(result.error, contains(tail), reason: '必须把 xray 尾部日志透出来');
      }
      expect(saved, isEmpty, reason: '0 可用的 run 不写历史');
    });

    test('K4：开测前是单线路代理 → 记下 stoppedUserProxy，结束后 mode 归零', () async {
      final server = await _serve(delayMs: 10);
      addTearDown(() => server.close(force: true));
      final xray = _FakeXray(initialMode: XrayMode.line);
      final runner = LinkTestRunner(
        speedUrl: _testUrl,
        latencyUrl: _testUrl,
        xray: xray,
        pool: _FixedPool(<int>[server.port]),
      );

      await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);

      expect(runner.stoppedUserProxy, isTrue);
      expect(xray.mode, XrayMode.none);
    });

    test('K4 反向：本来没有代理 → stoppedUserProxy 为假（不误提示）', () async {
      final server = await _serve(delayMs: 10);
      addTearDown(() => server.close(force: true));
      final runner = LinkTestRunner(
        speedUrl: _testUrl,
        latencyUrl: _testUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[server.port]),
      );

      await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);

      expect(runner.stoppedUserProxy, isFalse);
    });

    test('端口不足：抛可读文案且不启动进程', () async {
      final xray = _FakeXray();
      final runner = LinkTestRunner(
        speedUrl: _testUrl, latencyUrl: _testUrl,
        xray: xray,
        pool: _FixedPool(<int>[20000]), // 2 个节点只给 1 个端口
      );

      await expectLater(
        runner.run(<String>[
          _link('a.example', 443),
          _link('b.example', 8443),
        ]),
        throwsA(
          isA<LinkTestException>()
              .having((e) => e.message, 'message', contains('端口')),
        ),
      );
      expect(xray.startCalls, 0);
    });

    test('开测不依赖「直连测速源」：直连不可达也照常起进程并探测', () async {
      // 回归：旧实现会在开测前直连 speedUrl 探活，失败就整批拒绝；
      // 而测速流量本来就全走线路，直连不通是常态。这里把 speedUrl 指向
      // 死端口，验证仍然启动批量进程并真的发起探测。
      final server = await _serve(delayMs: 10);
      addTearDown(() => server.close(force: true));

      var probeCalls = 0;
      final xray = _FakeXray();
      final runner = LinkTestRunner(
        speedUrl: 'http://127.0.0.1:1/300.zip',
        latencyUrl: 'http://127.0.0.1:1/300.zip',
        xray: xray,
        pool: _FixedPool(<int>[server.port]),
        probeFactory: (speedUrl, latencyUrl, port) {
          probeCalls++;
          // 两个地址都改指本地服务：这条用例要验的是「不做直连探活」，
          // 不是「探测地址是否可达」。
          final reachable = 'http://127.0.0.1:${server.port}/300.zip';
          return LinkProbe(
            speedUrl: reachable,
            latencyUrl: reachable,
            localPort: port,
          );
        },
      );

      final run = await runner.run(
        <String>[_link('a.example', 443)],
        mode: LinkTestMode.latency,
      );

      expect(xray.startCalls, 1, reason: '不允许因为直连不通就拒绝开测');
      expect(probeCalls, 1, reason: '必须真的发起探测');
      expect(run.results.length, 1);
    });

    test('非法链接单独失败、其余照测（D1：不整批拒绝）', () async {
      final server = await _serve(delayMs: 10);
      addTearDown(() => server.close(force: true));
      final runner = LinkTestRunner(
        speedUrl: _testUrl,
        latencyUrl: _testUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[server.port]),
      );

      final run = await runner.run(
        <String>['not-a-vless-link', _link('a.example', 443)],
        mode: LinkTestMode.latency,
      );

      expect(run.results.length, 2);
      expect(run.results[0].state, ProbeState.failed);
      expect(run.results[0].error, contains('无法解析'));
      expect(run.results[1].error, isNull);
      expect(run.results[1].latencyKnown, isTrue);
    });

    test('取消：在途探测全部标 cancelled，已完成结果保留，进程被停掉', () async {
      final server = await _hang();
      addTearDown(() => server.close(force: true));
      final xray = _FakeXray();
      final runner = LinkTestRunner(
        speedUrl: _testUrl,
        latencyUrl: _testUrl,
        xray: xray,
        pool: _FixedPool(<int>[server.port, server.port]),
        probeFactory: (speedUrl, latencyUrl, port) => LinkProbe(
          speedUrl: speedUrl,
          latencyUrl: latencyUrl,
          localPort: port,
          latencyTimeout: const Duration(seconds: 10),
        ),
      );

      final pending = runner.run(<String>[
        _link('a.example', 443),
        _link('b.example', 8443),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await runner.cancel();
      final run = await pending;

      expect(runner.cancelled, isTrue);
      expect(
        run.results.every((r) => r.state == ProbeState.cancelled),
        isTrue,
        reason: '在途/未派发都必须标 cancelled',
      );
      expect(xray.stopCalls, greaterThanOrEqualTo(1), reason: '取消必须停掉批量进程');
    });

    test('落盘失败不阻断结果展示（T03 验收 5）', () async {
      final server = await _serve(delayMs: 10);
      addTearDown(() => server.close(force: true));
      final runner = LinkTestRunner(
        speedUrl: _testUrl,
        latencyUrl: _testUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[server.port]),
        saver: (run) async => throw const FileSystemException('磁盘满'),
      );

      final run = await runner.run(
        <String>[_link('a.example', 443)],
        mode: LinkTestMode.latency,
      );

      expect(run.results.single.latencyKnown, isTrue);
    });

    // -----------------------------------------------------------------------
    // 端点分离：延迟与速度是两条口径，runner 必须能分别持有、且「换地址」
    // 只对下一轮生效（同一轮混用会得到不可比的读数）。
    // -----------------------------------------------------------------------
    test('构造时给空地址 → 回落默认端点（否则每条线路都报「地址非法」）', () {
      final runner = LinkTestRunner(
        xray: _FakeXray(),
        speedUrl: '   ',
        latencyUrl: '',
      );

      expect(runner.speedUrl, kDefaultSpeedUrl);
      expect(runner.latencyUrl, kDefaultLatencyUrl);
    });

    test('configureUrls：下一轮打新端点；空串=**重置为默认**（不是忽略）', () async {
      final server = await _serve(delayMs: 10);
      addTearDown(() => server.close(force: true));
      final seen = <(String, String)>[];

      final runner = LinkTestRunner(
        speedUrl: 'http://old.test/300.zip',
        latencyUrl: 'http://old.test/generate_204',
        xray: _FakeXray(),
        pool: _FixedPool(<int>[server.port]),
        probeFactory: (speedUrl, latencyUrl, port) {
          seen.add((speedUrl, latencyUrl));
          // 真正探测打本地服务，避免依赖外部网络；地址只用来记录「传了什么」。
          return LinkProbe(
            speedUrl: _testUrl,
            latencyUrl: _testUrl,
            localPort: port,
          );
        },
      );

      await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);
      expect(seen.last,
          ('http://old.test/300.zip', 'http://old.test/generate_204'),
          reason: '默认工厂的参数顺序不能串（速度在前、延迟在后）');

      runner.configureUrls(
        speedUrl: 'http://new.test/300.zip',
        latencyUrl: '',
      );
      await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);

      expect(seen.last.$1, 'http://new.test/300.zip');
      expect(
        seen.last.$2,
        kDefaultLatencyUrl,
        reason: '空串 = 恢复默认（用户视角「清空输入框」就是「用默认」），'
            '不能沿用上一轮的自定义值，也不能真的拿空串去探测',
      );
      expect(runner.latencyUrl, kDefaultLatencyUrl);
      expect(
        seen.last.$1,
        isNot(isEmpty),
        reason: '速度地址同样有兜底：不能变成空串',
      );
    });

    test('configureUrls 传空格也算空：两个地址各自回落到自己的默认值', () {
      final runner = LinkTestRunner(
        xray: _FakeXray(),
        speedUrl: 'http://custom.test/300.zip',
        latencyUrl: 'http://custom.test/generate_204',
      );

      runner.configureUrls(speedUrl: '   ', latencyUrl: '  ');

      expect(runner.speedUrl, kDefaultSpeedUrl);
      expect(runner.latencyUrl, kDefaultLatencyUrl);
    });

    test('一轮被取消后同时发起两个 run：后到者被拒，且不能把先到者的登记清掉', () async {
      // 可切换入站：hang=true 挂住（第一轮），false 立刻回 204（后续轮次）。
      var hang = true;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (hang) return;
        final response = request.response;
        response.statusCode = HttpStatus.noContent;
        await response.close();
      });
      addTearDown(() => server.close(force: true));

      final runner = LinkTestRunner(
        speedUrl: _testUrl,
        latencyUrl: _testUrl,
        xray: _FakeXray(),
        pool: _FixedPool(<int>[server.port]),
        probeFactory: (speedUrl, latencyUrl, port) => LinkProbe(
          speedUrl: speedUrl,
          latencyUrl: latencyUrl,
          localPort: port,
          latencyTimeout: const Duration(seconds: 10),
        ),
      );

      final first = runner.run(
        <String>[_link('a.example', 443)],
        mode: LinkTestMode.latency,
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final cancelling = runner.cancel();
      hang = false;
      // 两个调用同时等第一轮收尾：先到者登记新一轮，后到者必须被拒。
      final winner = runner.run(
        <String>[_link('b.example', 8443)],
        mode: LinkTestMode.latency,
      );
      final loser = runner.run(
        <String>[_link('c.example', 9443)],
        mode: LinkTestMode.latency,
      );

      await expectLater(
        loser,
        throwsA(
          isA<LinkTestException>().having(
            (e) => e.message,
            'message',
            contains('还在进行'),
          ),
        ),
        reason: '第二轮不能被两个调用同时开起来',
      );

      await cancelling;
      await first;

      // 关键回归：后到者被拒后，**先到者的登记必须还在**。
      // 若登记被后到者清掉（修复前的行为：无条件赋值 + identical 判真清空），
      // 这里取消先到者后立刻再开一轮就会命中「上一次测速还在进行」——
      // 也就是 Bug A 换了个入口复发。
      await runner.cancel();
      final next = await runner.run(
        <String>[_link('d.example', 10443)],
        mode: LinkTestMode.latency,
      );
      expect(next.results.single.state, ProbeState.done);

      // 被取消的那一轮正常收尾（不是抛异常，也不是永远挂着）。
      final winnerRun = await winner;
      expect(winnerRun.results.single.state, ProbeState.cancelled);
    });

    // -----------------------------------------------------------------------
    // 候选端点自动切换（P1 / B 方案）：判定必须是**整批**层面的。
    // -----------------------------------------------------------------------
    test('候选链：首选 → 内置候选 → 速度端点，按字符串去重且保序', () {
      final withDefault = LinkTestRunner(
        xray: _FakeXray(),
        speedUrl: 'http://s.test/300.zip',
        latencyUrl: kDefaultLatencyUrl,
      );
      expect(
        withDefault.latencyCandidates(),
        <String>[
          kDefaultLatencyUrl,
          'https://www.gstatic.com/generate_204',
          'http://s.test/300.zip',
        ],
        reason: '首选与内置候选重复时必须只出现一次，速度端点永远在末尾',
      );

      // 用户把首选填成速度端点：去重后仍只出现一次，且位置在首位。
      final sameAsSpeed = LinkTestRunner(
        xray: _FakeXray(),
        speedUrl: 'http://s.test/300.zip',
        latencyUrl: 'http://s.test/300.zip',
      );
      expect(
        sameAsSpeed.latencyCandidates(),
        <String>[
          'http://s.test/300.zip',
          kDefaultLatencyUrl,
          'https://www.gstatic.com/generate_204',
        ],
      );
    });

    test('整批全失败 → 切到第二个候选（断言 probeFactory 收到的 URL）', () async {
      final seen = <String>[];
      final runner = LinkTestRunner(
        xray: _FakeXray(),
        speedUrl: 'http://speed.test/300.zip',
        latencyUrl: 'http://first.test/generate_204',
        pool: _FixedPool(<int>[20000, 20001]),
        probeFactory: (speedUrl, latencyUrl, port) {
          seen.add(latencyUrl);
          return _UrlScriptedProbe(
            speedUrl: speedUrl,
            latencyUrl: latencyUrl,
            localPort: port,
            onLatency: (url) async => LinkProbeOutcome.failure(
              '连接失败：Connection refused',
              5,
              kind: ProbeFailureKind.connect,
            ),
            inFlight: (_) {},
          );
        },
      );

      final run = await runner.run(
        <String>[_link('a.example', 443), _link('b.example', 8443)],
        mode: LinkTestMode.latency,
      );

      expect(run.results.length, 2);
      for (final result in run.results) {
        expect(result.state, ProbeState.failed);
        expect(result.latencyKnown, isFalse);
      }
      // 每一轮都用同一个端点探测整批，所以每个候选各出现 2 次。
      expect(
          seen.where((u) => u == 'http://first.test/generate_204').length, 2);
      expect(seen.where((u) => u == kDefaultLatencyUrl).length, 2,
          reason: '整批都没有延迟 → 必须换到第二个候选重跑');
      expect(seen.first, 'http://first.test/generate_204', reason: '首选先跑');
    });

    test('只要有一条拿到延迟就不切换（失败的那些是真死链）', () async {
      final seen = <String>[];
      final runner = LinkTestRunner(
        xray: _FakeXray(),
        speedUrl: 'http://speed.test/300.zip',
        latencyUrl: 'http://first.test/generate_204',
        pool: _FixedPool(<int>[20000, 20001]),
        probeFactory: (speedUrl, latencyUrl, port) {
          seen.add(latencyUrl);
          // a 通、b 死：端点本身没问题，b 是死链。
          final ok =
              latencyUrl == 'http://first.test/generate_204' && port == 20000;
          return _UrlScriptedProbe(
            speedUrl: speedUrl,
            latencyUrl: latencyUrl,
            localPort: port,
            onLatency: (_) async => ok
                ? const LinkProbeOutcome(ttfbMs: 42, elapsedMs: 42)
                : LinkProbeOutcome.failure(
                    '连接失败：Connection refused',
                    5,
                    kind: ProbeFailureKind.connect,
                  ),
            inFlight: (_) {},
          );
        },
      );

      final run = await runner.run(
        <String>[_link('a.example', 443), _link('b.example', 8443)],
        mode: LinkTestMode.latency,
      );

      expect(seen.length, 2, reason: '只该跑一轮：有 1 条成功就不重试');
      expect(seen.every((u) => u == 'http://first.test/generate_204'), isTrue,
          reason: '第二个候选必须零调用');
      final okResult = run.results.firstWhere((r) => r.latencyKnown);
      expect(okResult.latencyMs, 42, reason: '成功条目的延迟不能被重跑覆盖');
      expect(run.results.where((r) => r.error != null).length, 1,
          reason: '死链仍是失败，但不会因为端点切换被洗白');
    });

    test('最多切 2 次：三端点全失败时第 4 个候选零调用', () async {
      final seen = <String>[];
      final runner = LinkTestRunner(
        xray: _FakeXray(),
        speedUrl: 'http://fourth.test/300.zip',
        latencyUrl: 'http://first.test/generate_204',
        pool: _FixedPool(<int>[20000]),
        probeFactory: (speedUrl, latencyUrl, port) {
          seen.add(latencyUrl);
          return _UrlScriptedProbe(
            speedUrl: speedUrl,
            latencyUrl: latencyUrl,
            localPort: port,
            // 建连类才会触发切换（超时不算端点坏，见 runner 的判定）。
            onLatency: (_) async => LinkProbeOutcome.failure(
              '连接失败：Connection refused',
              5,
              kind: ProbeFailureKind.connect,
            ),
            inFlight: (_) {},
          );
        },
      );

      await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);

      // 候选链有 4 个（首选 + 2 个内置 + 速度端点），但只允许试 3 个。
      expect(runner.latencyCandidates().length, 4);
      expect(seen.length, kLatencyMaxAttempts);
      expect(seen.contains('http://fourth.test/300.zip'), isFalse,
          reason: '速度端点作为兜底候选，超了上限就不该被试');
    });

    test('整批纯超时 → 只切一次（分辨端点坏/线路慢的上限），第二轮超时就停', () async {
      final seen = <String>[];
      final logs = <String>[];
      final stageLabels = <String>[];
      final runner = LinkTestRunner(
        xray: _FakeXray(),
        speedUrl: 'http://speed.test/300.zip',
        latencyUrl: 'http://first.test/generate_204',
        pool: _FixedPool(<int>[20000]),
        probeFactory: (speedUrl, latencyUrl, port) {
          seen.add(latencyUrl);
          return _UrlScriptedProbe(
            speedUrl: speedUrl,
            latencyUrl: latencyUrl,
            localPort: port,
            onLatency: (_) async => LinkProbeOutcome.failure(
              kProbeTimeout,
              kLatencyTimeout.inMilliseconds,
              kind: ProbeFailureKind.timeout,
            ),
            inFlight: (_) {},
          );
        },
        onLog: logs.add,
      );

      final run = await runner.run(
        <String>[_link('a.example', 443)],
        mode: LinkTestMode.latency,
        onProgress: (results, stage) {
          if (stageLabels.isEmpty || stageLabels.last != stage) {
            stageLabels.add(stage);
          }
        },
      );

      expect(
        seen.length,
        2,
        reason: '纯超时既可能是端点被墙、也可能是节点慢：允许切一次去分辨；'
            '第二个端点同样超时就停（不许切到第 3 个）',
      );
      expect(seen.first, 'http://first.test/generate_204');
      expect(seen.last, kDefaultLatencyUrl, reason: '第二次用的是内置候选');
      expect(run.results.single.state, ProbeState.failed);
      expect(
        logs.any((l) => l.contains('试下一个候选')),
        isTrue,
        reason: '首轮切换必须给出依据',
      );
      expect(
        logs.any((l) => l.contains('判为线路慢，停止切换端点')),
        isTrue,
        reason: '第二轮仍超时要说明「为什么不再切」',
      );
      expect(
        stageLabels.last,
        contains('请更换「延迟测试地址」'),
        reason: '全批没测出延迟时，结论要出现在**阶段文案**上（用户不一定看日志）',
      );
    });

    test('超时 + 建连失败混合 → 保守不切换', () async {
      final seen = <String>[];
      var call = 0;
      final runner = LinkTestRunner(
        xray: _FakeXray(),
        speedUrl: 'http://speed.test/300.zip',
        latencyUrl: 'http://first.test/generate_204',
        pool: _FixedPool(<int>[20000, 20001]),
        probeFactory: (speedUrl, latencyUrl, port) {
          seen.add(latencyUrl);
          call++;
          final kind =
              call == 1 ? ProbeFailureKind.timeout : ProbeFailureKind.connect;
          return _UrlScriptedProbe(
            speedUrl: speedUrl,
            latencyUrl: latencyUrl,
            localPort: port,
            onLatency: (_) async => LinkProbeOutcome.failure(
              kind == ProbeFailureKind.timeout ? kProbeTimeout : '连接失败',
              kLatencyTimeout.inMilliseconds,
              kind: kind,
            ),
            inFlight: (_) {},
          );
        },
      );

      await runner.run(
        <String>[_link('a.example', 443), _link('b.example', 8443)],
        mode: LinkTestMode.latency,
      );

      expect(
        seen.every((u) => u == 'http://first.test/generate_204'),
        isTrue,
        reason: '有一条超时说明链路至少部分是活的，切端点救不了',
      );
      expect(seen.length, 2, reason: '只跑一轮（每条一次）');
    });

    test('整批都是建连类失败 → 才切换端点', () async {
      final seen = <String>[];
      final runner = LinkTestRunner(
        xray: _FakeXray(),
        speedUrl: 'http://speed.test/300.zip',
        latencyUrl: 'http://first.test/generate_204',
        pool: _FixedPool(<int>[20000, 20001]),
        probeFactory: (speedUrl, latencyUrl, port) {
          seen.add(latencyUrl);
          return _UrlScriptedProbe(
            speedUrl: speedUrl,
            latencyUrl: latencyUrl,
            localPort: port,
            onLatency: (_) async => LinkProbeOutcome.failure(
              'TLS 握手失败：bad certificate',
              30,
              kind: ProbeFailureKind.tlsHandshake,
            ),
            inFlight: (_) {},
          );
        },
      );

      await runner.run(
        <String>[_link('a.example', 443), _link('b.example', 8443)],
        mode: LinkTestMode.latency,
      );

      expect(
          seen.where((u) => u == 'http://first.test/generate_204').length, 2);
      expect(seen.where((u) => u == kDefaultLatencyUrl).length, 2,
          reason: 'TLS 握手失败属建连类，整批如此才说明端点不可达');
    });

    test('首轮阶段文案不带「端点 1/3」（健康网络不该看起来像在重试）', () async {
      final stages = <String>[];
      final runner = LinkTestRunner(
        xray: _FakeXray(),
        speedUrl: 'http://speed.test/300.zip',
        latencyUrl: 'http://first.test/generate_204',
        pool: _FixedPool(<int>[20000]),
        probeFactory: (speedUrl, latencyUrl, port) => _UrlScriptedProbe(
          speedUrl: speedUrl,
          latencyUrl: latencyUrl,
          localPort: port,
          onLatency: (_) async =>
              const LinkProbeOutcome(ttfbMs: 30, elapsedMs: 30),
          inFlight: (_) {},
        ),
      );

      await runner.run(
        <String>[_link('a.example', 443)],
        mode: LinkTestMode.latency,
        onProgress: (results, stage) {
          if (stages.isEmpty || stages.last != stage) stages.add(stage);
        },
      );

      // 第一帧是「准备中」，延迟阶段的文案紧随其后。
      expect(stages, contains('延迟探测'));
      expect(
        stages.any((s) => s.contains('端点 1/')),
        isFalse,
        reason: '首轮就写「端点 1/3」会让用户以为已经在重试',
      );
    });

    test('切换判定不依赖文案：超时文案改了，行为仍是「切一次」而不是「按文字判定」', () async {
      final seen = <String>[];
      final runner = LinkTestRunner(
        xray: _FakeXray(),
        speedUrl: 'http://speed.test/300.zip',
        latencyUrl: 'http://first.test/generate_204',
        pool: _FixedPool(<int>[20000]),
        probeFactory: (speedUrl, latencyUrl, port) {
          seen.add(latencyUrl);
          return _UrlScriptedProbe(
            speedUrl: speedUrl,
            latencyUrl: latencyUrl,
            localPort: port,
            // 故意换一个**完全不同的文案**，但类别仍是 timeout。
            onLatency: (_) async => LinkProbeOutcome.failure(
              '超时（5s 内未收到首字节）',
              kLatencyTimeout.inMilliseconds,
              kind: ProbeFailureKind.timeout,
            ),
            inFlight: (_) {},
          );
        },
      );

      await runner
          .run(<String>[_link('a.example', 443)], mode: LinkTestMode.latency);

      expect(
        seen.length,
        2,
        reason: '判定读 failureKind：自定义文案仍是 timeout → 切一次；'
            '若退回字符串比较，这段文字会被当成「非建连类」→ 只跑 1 次',
      );
    });

    test('重跑会重新派发探测，但预检失败的 error 不能被清掉', () async {
      var probeCalls = 0;
      final runner = LinkTestRunner(
        xray: _FakeXray(),
        speedUrl: 'http://speed.test/300.zip',
        latencyUrl: 'http://first.test/generate_204',
        pool: _FixedPool(<int>[20000]),
        probeFactory: (speedUrl, latencyUrl, port) {
          probeCalls++;
          return _UrlScriptedProbe(
            speedUrl: speedUrl,
            latencyUrl: latencyUrl,
            localPort: port,
            onLatency: (_) async => LinkProbeOutcome.failure(
              '连接失败：Connection refused',
              5,
              kind: ProbeFailureKind.connect,
            ),
            inFlight: (_) {},
          );
        },
      );

      final run = await runner.run(
        <String>['not-a-vless-link', _link('a.example', 443)],
        mode: LinkTestMode.latency,
      );

      expect(probeCalls, kLatencyMaxAttempts, reason: '合法那条被重跑了 3 次');
      expect(
        run.results[0].error,
        contains('无法解析'),
        reason: '预检失败不可恢复，重跑不能把它清成「端点不可达」',
      );
      expect(run.results[1].state, ProbeState.failed);
    });

    test('重试路径的并发峰值仍是 6（不许绕过闸门）', () async {
      var inFlight = 0;
      var peak = 0;
      final urls = <String>[];

      final runner = LinkTestRunner(
        xray: _FakeXray(),
        speedUrl: 'http://speed.test/300.zip',
        latencyUrl: 'http://first.test/generate_204',
        pool: _FixedPool(<int>[for (var i = 0; i < 8; i++) 20000 + i]),
        probeFactory: (speedUrl, latencyUrl, port) {
          urls.add(latencyUrl);
          return _UrlScriptedProbe(
            speedUrl: speedUrl,
            latencyUrl: latencyUrl,
            localPort: port,
            inFlight: (delta) {
              inFlight += delta;
              if (inFlight > peak) peak = inFlight;
            },
            onLatency: (_) async {
              await Future<void>.delayed(const Duration(milliseconds: 5));
              return LinkProbeOutcome.failure(
                '连接失败：Connection refused',
                5,
                kind: ProbeFailureKind.connect,
              );
            },
          );
        },
      );

      await runner.run(
        <String>[for (var i = 0; i < 8; i++) _link('h$i.example', 443 + i)],
        mode: LinkTestMode.latency,
      );

      expect(peak, kLatencyParallel,
          reason: '重试必须复用同一个 _stage/闸门；复制一条派发路径会让峰值变 12/18');
      expect(urls.length, 8 * kLatencyMaxAttempts, reason: '三轮 × 8 条都派发过');
    });

    test('一轮里延迟用延迟地址、速度用速度地址（不许混成一个 URL）', () async {
      final server = await _serve(
        delayMs: 10,
        bodyBytes: kWarmupBytes + 2 * 1024 * 1024,
      );
      addTearDown(() => server.close(force: true));
      final seen = <(String, String)>[];

      final runner = LinkTestRunner(
        speedUrl: 'http://speed-only.test/300.zip',
        latencyUrl: 'http://latency-only.test/generate_204',
        xray: _FakeXray(),
        pool: _FixedPool(<int>[server.port]),
        probeFactory: (speedUrl, latencyUrl, port) {
          seen.add((speedUrl, latencyUrl));
          return LinkProbe(
            speedUrl: _testUrl,
            latencyUrl: _testUrl,
            localPort: port,
          );
        },
      );

      final run = await runner.run(<String>[_link('a.example', 443)]);

      expect(run.results.single.speedMib, isNotNull, reason: 'auto 模式要能测出速度');
      expect(seen.length, 2, reason: '延迟 1 个 + 速度 1 个');
      // 两个探测都拿到同一对端点；真正的「谁用哪个」由 LinkProbe.latency/speed
      // 各自取 latencyUrl/speedUrl 决定（见 test/link_probe_test.dart 的端点分离用例）。
      expect(
          seen.every((e) => e.$1 == 'http://speed-only.test/300.zip'), isTrue);
      expect(seen.every((e) => e.$2 == 'http://latency-only.test/generate_204'),
          isTrue);
    });

    // -----------------------------------------------------------------------
    // 慢但活着的节点 ≠ 端点故障（判定细节见上面「候选端点」那组用例）。
    //
    // 这里只补两条**别的用例覆盖不到**的：
    // ① 判定的自变量是 `failureKind` 标志位，而不是 `error` 的文案 —— 反向也要成立
    //    （文案恰好是 kProbeTimeout 但类别是建连失败时，必须照旧换端点）；
    // ② 预检失败（vless://bad）既不参与超时统计，也不许被清 error / 被重跑。
    // -----------------------------------------------------------------------
    test('判定只看标志位、不看文案：文案换掉仍不切换；文案是「超时」但标志位为假则切换', () async {
      // ① 文案是自定义的一句话（模拟日后改文案），但结构化类别是 timeout。
      final seenCustom = <String>[];
      final runnerCustom = _batchRunner(
        ports: <int>[20000],
        seen: seenCustom,
        onLog: (_) {},
        onLatency: (url, port) async => LinkProbeOutcome.failure(
          '首字节迟迟不来（自定义文案）',
          kLatencyTimeout.inMilliseconds,
          kind: ProbeFailureKind.timeout,
        ),
      );
      await runnerCustom.run(
        <String>[_link('a.example', 443)],
        mode: LinkTestMode.latency,
      );
      expect(
        seenCustom.length,
        2,
        reason: '判定读的是标志位：纯超时 → 首轮切一次、第二轮停止；'
            '若还在比字符串，这段自定义文案会被当成「非超时非建连类」→ 只跑 1 次',
      );

      // ② 文案**恰好等于** kProbeTimeout，但类别是建连失败 → 仍然要切换。
      final seenText = <String>[];
      final runnerText = _batchRunner(
        ports: <int>[20000],
        seen: seenText,
        onLog: (_) {},
        onLatency: (url, port) async => LinkProbeOutcome.failure(
          kProbeTimeout,
          5,
          kind: ProbeFailureKind.connect,
        ),
      );
      final runText = await runnerText.run(
        <String>[_link('a.example', 443)],
        mode: LinkTestMode.latency,
      );
      expect(seenText.length, kLatencyMaxAttempts,
          reason: '文案等于 kProbeTimeout 也不能被当成超时（否则改文案就静默变行为）');
      expect(runText.results.single.timedOut, isFalse,
          reason: 'error 文案是「超时」但标志位为假：证明判定没在读文案');
    });

    test('预检失败不计入超时统计：error 不被清掉、不参与重跑', () async {
      var probeCalls = 0;
      final logs = <String>[];
      final runner = LinkTestRunner(
        xray: _FakeXray(),
        speedUrl: 'http://speed.test/300.zip',
        latencyUrl: 'http://first.test/generate_204',
        pool: _FixedPool(<int>[20000]),
        onLog: logs.add,
        probeFactory: (speedUrl, latencyUrl, port) {
          probeCalls++;
          return _UrlScriptedProbe(
            speedUrl: speedUrl,
            latencyUrl: latencyUrl,
            localPort: port,
            inFlight: (_) {},
            onLatency: (_) async => _timeoutOutcome(),
          );
        },
      );

      final run = await runner.run(
        <String>['not-a-vless-link', _link('a.example', 443)],
        mode: LinkTestMode.latency,
      );

      expect(
        probeCalls,
        2,
        reason: '预检失败那条从不派发；合法那条纯超时 → 首轮切一次、第二轮停止',
      );
      expect(run.results[0].host, isEmpty);
      expect(run.results[0].error, contains('无法解析'),
          reason: '预检失败不可恢复，不能被清成「端点不可达」');
      expect(run.results[0].timedOut, isFalse, reason: '预检失败不是超时');
      expect(run.results[1].latencyKnown, isFalse);
      expect(run.results[1].timedOut, isTrue);
      expect(
        logs.any((l) => l.contains('停止切换端点')),
        isTrue,
        reason: '第二轮仍超时 → 停止切换（不是「第一轮就不切」）',
      );
    });
  });

  group('AppState 代理停掉提示（one-shot，R12 §9.1 禁止持久 bool）', () {
    test('读一次即清空，第二次为 null（提示不会反复出现/僵死）', () {
      final state = AppState()
        ..debugSetProxyStopNoticeForTest(kProxyStoppedByTestMessage);

      expect(state.takeProxyStopNotice(), kProxyStoppedByTestMessage);
      expect(
        state.takeProxyStopNotice(),
        isNull,
        reason: '必须读取即消费，否则用户改链接重进后提示会永久僵死',
      );
    });

    test('没有停过代理时返回 null（不误提示）', () {
      expect(AppState().takeProxyStopNotice(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // 独立审计挖出的三处缺口（K4 失败路径 / drain 守卫 / 防重入）
  // -------------------------------------------------------------------------
  group('K4 失败路径：代理已被杀就必须记账', () {
    test('startBatch 两次都失败时 stoppedUserProxy 仍为 true（否则用户永远不知情）', () async {
      // 关键：真实 startBatch 第一行就是 await stop()，所以「失败」不代表「没动过代理」
      final xray = _FakeXray(
        initialMode: XrayMode.line,
        startError: 'failed to bind 20000',
      );
      final runner = LinkTestRunner(
        speedUrl: _testUrl,
        latencyUrl: _testUrl,
        xray: xray,
        pool: _FixedPool(<int>[20000]),
      );

      final run = await runner.run(<String>[_link('a.example', 443)]);

      expect(run.results.single.state, ProbeState.failed);
      expect(
        runner.stoppedUserProxy,
        isTrue,
        reason: '代理在 startBatch 里已被 stop()，无论成败都必须置位，否则 UI 不提示',
      );
      // ② 重试路径：一次 run 会调 startBatch 两次（首次失败 → 重挑端口 → 再失败），
      //    两次都在内部 stop()，所以「重试」也必须被这条断言覆盖到。
      expect(xray.startCalls, 2, reason: '必须覆盖「重试分支也照样会 stop」');
      expect(xray.mode, XrayMode.none);
    });

    test('本来就没有代理时，失败路径也不该误报（不误提示）', () async {
      final runner = LinkTestRunner(
        speedUrl: _testUrl,
        latencyUrl: _testUrl,
        xray: _FakeXray(startError: 'boom'),
        pool: _FixedPool(<int>[20000]),
      );

      await runner.run(<String>[_link('a.example', 443)]);

      expect(runner.stoppedUserProxy, isFalse);
    });
  });

  group('取消必须真的挡住排队者（节点数 > 闸门许可才有等待者）', () {
    test('8 个节点（6 许可）：取消后不再创建任何新探测', () async {
      final server = await _hang();
      addTearDown(() => server.close(force: true));
      var probeCalls = 0;
      final runner = LinkTestRunner(
        speedUrl: _testUrl, latencyUrl: _testUrl,
        xray: _FakeXray(),
        // 8 个节点共用同一个「接了不回包」的端口 → 6 个在跑、2 个排队
        pool: _FixedPool(List<int>.filled(8, server.port)),
        probeFactory: (speedUrl, latencyUrl, port) {
          probeCalls++;
          return LinkProbe(
            speedUrl: speedUrl,
            latencyUrl: latencyUrl,
            localPort: port,
            latencyTimeout: const Duration(seconds: 10),
          );
        },
      );

      final future = runner.run(
        <String>[for (var i = 0; i < 8; i++) _link('h$i.example', 443 + i)],
        mode: LinkTestMode.latency,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final before = probeCalls;
      expect(before, kLatencyParallel, reason: '闸门 6 许可，最多 6 个探测在跑');

      await runner.cancel();
      final run = await future;

      // drain() 若失效，排队者会被放行 → probeCalls 会涨到 8
      expect(probeCalls, before, reason: '取消后不得再派发探测（排队者必须被 drain 拦住）');
      expect(
        run.results.every((r) => r.state == ProbeState.cancelled),
        isTrue,
        reason: '在跑与排队的条目都必须标 cancelled',
      );
    });
  });

  group('AppState 防重入（第二次调用不能污染第一轮）', () {
    test('测速进行中再次 runLinkTest：返回 false、不清进度、不把「在跑」标成「没跑」', () async {
      final server = await _hang();
      addTearDown(() => server.close(force: true));
      final state = AppState(
        runner: LinkTestRunner(
          speedUrl: _testUrl,
          latencyUrl: _testUrl,
          xray: _FakeXray(),
          pool: _FixedPool(<int>[server.port]),
          probeFactory: (speedUrl, latencyUrl, port) => LinkProbe(
            speedUrl: speedUrl,
            latencyUrl: latencyUrl,
            localPort: port,
            latencyTimeout: const Duration(seconds: 10),
          ),
        ),
      );

      final first = state.runLinkTest(<String>[_link('a.example', 443)]);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(state.linkTestRunning, isTrue);
      final progressBefore = state.linkResults;

      final second =
          await state.runLinkTest(<String>[_link('b.example', 8443)]);

      expect(second, isFalse);
      expect(state.linkTestError, contains('测速'));
      expect(
        state.linkTestRunning,
        isTrue,
        reason: '第一轮还在跑，第二次调用不能把状态改成「没在跑」',
      );
      expect(
        identical(state.linkResults, progressBefore) ||
            state.linkResults.isNotEmpty,
        isTrue,
        reason: '第一轮的进度不能被清空',
      );

      await state.cancelLinkTest();
      await first;
      expect(state.linkTestRunning, isFalse);
    });

    // QA 独立审出的缺口：取消后立刻再开一轮时，**第一轮** `await runLinkTest`
    // 的续体比第二轮启动更晚恢复，它会拿着第一轮的结果去写 AppState 的副本状态，
    // 把「第二轮正在跑」踩成「完成 + 第一轮的已取消结果」。
    // UI 上点不出来（按钮在 linkTestRunning 时禁用），但 API 层可复现。
    test('取消后立刻再开一轮：第一轮的迟到收尾不能踩掉第二轮的状态', () async {
      // 一个可切换的入站：hang=true 时接了不回包，false 时压 400ms 再回 204。
      var hang = true;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (hang) return; // 第一轮：挂住，等 cancel
        final response = request.response;
        await Future<void>.delayed(const Duration(milliseconds: 400));
        response.statusCode = HttpStatus.noContent;
        await response.close();
      });
      addTearDown(() => server.close(force: true));

      final state = AppState(
        runner: LinkTestRunner(
          speedUrl: _testUrl,
          latencyUrl: _testUrl,
          xray: _FakeXray(),
          pool: _FixedPool(<int>[server.port]),
          probeFactory: (speedUrl, latencyUrl, port) => LinkProbe(
            speedUrl: speedUrl,
            latencyUrl: latencyUrl,
            localPort: port,
            latencyTimeout: const Duration(seconds: 10),
          ),
        ),
      );

      final first = state.runLinkTest(
        <String>[_link('a.example', 443)],
        mode: LinkTestMode.latency,
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(state.linkTestRunning, isTrue);

      final cancelling = state.cancelLinkTest();
      hang = false;
      final second = state.runLinkTest(
        <String>[_link('b.example', 8443)],
        mode: LinkTestMode.latency,
      );

      await cancelling;
      await first; // 第一轮正式收尾 —— 此刻第二轮仍在探测中（服务端压 400ms）

      expect(
        state.linkTestRunning,
        isTrue,
        reason: '第二轮在跑，第一轮的 finally 不能把「没在跑」写回来',
      );
      expect(
        state.linkStage,
        isNot('完成'),
        reason: '更不能把阶段写成「完成」（第一轮读到的是被第二轮重置过的 cancelled=false）',
      );
      expect(
        state.linkResults.any((r) => r.state == ProbeState.cancelled),
        isFalse,
        reason: '第一轮的「已取消」结果不能贴到第二轮的列表上',
      );

      await second;
      expect(state.linkTestRunning, isFalse);
      expect(state.linkResults.single.state, ProbeState.done);
      expect(state.linkStage, '完成');
    });

    test('cancelLinkTest 的 await 期间新轮已起：不许把新轮的阶段改回「已取消」', () async {
      // 这条时序敏感，**不用 sleep 碰运气**：用两个 Completer 精确控制
      // ① 探测何时返回（`_GatedProbe`）；② `_xray.stop()` 何时返回（`_GatedXray.gate`，
      //    也就是 `runner.cancel()` 卡在哪一刻）。
      final xray = _GatedXray();
      final probes = <_GatedProbe>[];
      final firstProbe = Completer<void>();
      final secondProbe = Completer<void>();
      final state = AppState(
        runner: LinkTestRunner(
          speedUrl: _testUrl,
          latencyUrl: _testUrl,
          xray: xray,
          pool: _FixedPool(<int>[20000]),
          probeFactory: (speedUrl, latencyUrl, port) {
            final probe = _GatedProbe(localPort: port);
            probes.add(probe);
            if (probes.length == 1) {
              if (!firstProbe.isCompleted) firstProbe.complete();
            } else if (!secondProbe.isCompleted) {
              secondProbe.complete();
            }
            return probe;
          },
        ),
      );

      final first = state.runLinkTest(
        <String>[_link('a.example', 443)],
        mode: LinkTestMode.latency,
      );
      // 第一轮已派发探测，且它卡在自己的 gate 上：事件循环再怎么转也不会前进。
      await firstProbe.future;

      // 让 cancel 的 `_xray.stop()` 挂住 —— 这段时间正是「用户点了取消、
      // 又立刻点了开始」的窗口。
      final stopGate = Completer<void>();
      xray.gate = stopGate;
      final cancelling = state.cancelLinkTest();

      // 第二轮立刻起来：`linkStage` 在 runLinkTest 里是**同步**写的，
      // 所以这里不用等任何异步信号就能确定它已经是「准备中」。
      final second = state.runLinkTest(
        <String>[_link('b.example', 8443)],
        mode: LinkTestMode.latency,
      );
      expect(state.linkStage, '准备中', reason: '前置条件：第二轮已接管阶段字段');

      // 放行第一轮的 cancel 收尾 —— 它此刻才恢复执行，并拿到过期令牌。
      stopGate.complete();
      await cancelling;

      expect(
        state.linkStage,
        '准备中',
        reason: '取消的迟到收尾不能把第二轮刚写的「准备中」改回「已取消」',
      );
      expect(state.linkTestRunning, isTrue, reason: '第二轮仍在跑');

      // 收尾：等第二轮也派发出探测（否则它自己卡在等待上一轮/等待探测里），
      // 再统一放行，让两轮都正常结束。
      await secondProbe.future;
      for (final probe in probes) {
        probe.release();
      }
      await first;
      await second;
    });

    test('什么都不在跑时点取消：不该凭空显示「已取消」', () async {
      final state = AppState(runner: LinkTestRunner(xray: _FakeXray()));

      await state.cancelLinkTest();

      expect(state.linkStage, isEmpty);
      expect(state.linkTestRunning, isFalse);
    });

    test('注入 runner 时测速日志仍然进 state.logs（onLog 接线不能断）', () async {
      final server = await _serve(delayMs: 10);
      addTearDown(() => server.close(force: true));
      final state = AppState(
        // 关键：走**注入**那条路。构造参数里的 onLog 在这条路上不会执行，
        // 没有 ensureLogSink 的话日志面板会一片空白。
        runner: LinkTestRunner(
          speedUrl: _testUrl,
          latencyUrl: _testUrl,
          xray: _FakeXray(),
          pool: _FixedPool(<int>[server.port]),
        ),
      );

      await state.runLinkTest(
        <String>[_link('a.example', 443)],
        mode: LinkTestMode.latency,
      );

      expect(
        state.logs.any((l) => l.contains('端点：延迟=')),
        isTrue,
        reason: '开测时要打一行「这一轮打的是哪个端点」，注入 runner 时也得有',
      );
      expect(
        state.logs.any((l) => l.contains('ttfb=') && l.contains('建连=')),
        isTrue,
        reason: '每条探测的分项计时必须能到用户眼前（LogPanel 读的就是 state.logs）',
      );
    });
  });

  group('LinkTestStore 落盘（保留 20 条）', () {
    test('写 21 次只剩 20 个文件，list 最新在前', () async {
      final dir =
          await Directory.systemTemp.createTemp('cytest_linktest_store');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final store = LinkTestStore(dir: dir);

      for (var i = 1; i <= 21; i++) {
        await store.save(LinkTestRun(
          id: '${1000 + i}',
          createdAt: 1000 + i,
          mode: LinkTestMode.latency,
          results: const <LinkTestResult>[],
        ));
      }

      final files =
          await dir.list().where((e) => e.path.endsWith('.json')).toList();
      expect(files.length, 20);

      final runs = await store.list();
      expect(runs.first.createdAt, 1021, reason: '最新在前');
      expect(runs.any((r) => r.createdAt == 1001), isFalse, reason: '最旧的被裁掉');
    });

    test('坏 JSON 文件被跳过，不影响其余历史', () async {
      final dir =
          await Directory.systemTemp.createTemp('cytest_linktest_store_bad');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final store = LinkTestStore(dir: dir);
      await store.save(const LinkTestRun(
        id: '2000',
        createdAt: 2000,
        mode: LinkTestMode.auto,
        results: <LinkTestResult>[],
      ));
      await File('${dir.path}/2001.json').writeAsString('{"半截');

      final runs = await store.list();

      expect(runs.length, 1);
      expect(runs.single.id, '2000');
    });
  });
}
