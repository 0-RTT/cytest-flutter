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
        speedUrl: 'http://speed.test/300.zip',
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
        speedUrl: 'http://speed.test/300.zip',
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

    test('auto 模式：死链只有延迟阶段，不进速度阶段（省 3s 空转）', () async {
      // 拿一个「一定没人监听」的端口：bind 后立刻关掉
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();

      var probeCalls = 0;
      final runner = LinkTestRunner(
        speedUrl: 'http://speed.test/300.zip',
        xray: _FakeXray(),
        pool: _FixedPool(<int>[deadPort]),
        probeFactory: (url, port) {
          probeCalls++;
          return LinkProbe(
            speedUrl: url,
            localPort: port,
            latencyTimeout: const Duration(seconds: 2),
          );
        },
      );

      final run = await runner.run(<String>[_link('dead.example', 443)]);

      expect(run.results.single.error, isNotNull);
      expect(run.results.single.state, ProbeState.failed);
      expect(probeCalls, 1, reason: '死链只应被探测一次（不进速度阶段）');
    });

    test('K5 正控制：门禁通过时探针**确实被调用**（证明计数器会动）', () async {
      final server = await _serve(delayMs: 10);
      addTearDown(() => server.close(force: true));
      var probeCalls = 0;
      final runner = LinkTestRunner(
        speedUrl: 'http://speed.test/300.zip',
        xray: _FakeXray(),
        pool: _FixedPool(<int>[server.port]),
        probeFactory: (url, port) {
          probeCalls++;
          return LinkProbe(speedUrl: url, localPort: port);
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
        speedUrl: 'http://speed.test/300.zip',
        xray: _FakeXray(startError: tail),
        pool: _FixedPool(<int>[20000, 20001]),
        saver: (run) async => saved.add(run),
        probeFactory: (url, port) {
          probeCalls++;
          return LinkProbe(speedUrl: url, localPort: port);
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
        speedUrl: 'http://speed.test/300.zip',
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
        speedUrl: 'http://speed.test/300.zip',
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
        speedUrl: 'http://speed.test/300.zip',
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
        xray: xray,
        pool: _FixedPool(<int>[server.port]),
        probeFactory: (url, port) {
          probeCalls++;
          return LinkProbe(speedUrl: 'http://127.0.0.1:${server.port}/300.zip',
              localPort: port);
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
        speedUrl: 'http://speed.test/300.zip',
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
        speedUrl: 'http://speed.test/300.zip',
        xray: xray,
        pool: _FixedPool(<int>[server.port, server.port]),
        probeFactory: (url, port) => LinkProbe(
          speedUrl: url,
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
        speedUrl: 'http://speed.test/300.zip',
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
        speedUrl: 'http://speed.test/300.zip',
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
        speedUrl: 'http://speed.test/300.zip',
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
        speedUrl: 'http://speed.test/300.zip',
        xray: _FakeXray(),
        // 8 个节点共用同一个「接了不回包」的端口 → 6 个在跑、2 个排队
        pool: _FixedPool(List<int>.filled(8, server.port)),
        probeFactory: (url, port) {
          probeCalls++;
          return LinkProbe(
            speedUrl: url,
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
          speedUrl: 'http://speed.test/300.zip',
            xray: _FakeXray(),
          pool: _FixedPool(<int>[server.port]),
          probeFactory: (url, port) => LinkProbe(
            speedUrl: url,
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
