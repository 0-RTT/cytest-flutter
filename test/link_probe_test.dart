import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/link_probe.dart';

void main() {
  group('SpeedMeter 预热与窗口（常量对齐 Kotlin LinkProbe）', () {
    test('常量就是 Kotlin 的那四个：256KiB / 3000ms / 64MiB / 1000ms', () {
      final meter = SpeedMeter();

      expect(meter.warmupBytes, 262144);
      expect(meter.budgetMs, 3000);
      expect(meter.maxBytes, 67108864);
      expect(meter.minWindowMs, 1000);
    });

    test('只读 256KiB 以内：sample() 为 null（未测），但首字节已记录', () {
      final meter = SpeedMeter()..onChunk(1024 * 100, 30);

      expect(meter.sample(), isNull);
      expect(meter.firstByteMs, 30);
      expect(meter.warmupDone, isFalse);
      expect(meter.total, 1024 * 100);
    });

    test('一个字节都没读到时 firstByteMs 仍为 -1', () {
      final meter = SpeedMeter();

      expect(meter.sample(), isNull);
      expect(meter.firstByteMs, -1);
      expect(meter.total, 0);
    });

    test('恰好读满 256KiB 起算窗口：此时窗口内为 0 字节，sample() 仍为 null', () {
      final meter = SpeedMeter()..onChunk(262144, 5);

      expect(meter.warmupDone, isTrue);
      expect(meter.windowBytes, 0);
      expect(meter.sample(), isNull);
    });

    test('跨预热阈值的单个 chunk：只有超出部分计入窗口', () {
      final meter = SpeedMeter()
        ..onChunk(131072, 1) // 预热一半
        ..onChunk(262144, 2); // 再来的这块补齐预热，剩余 131072 进窗口

      expect(meter.warmupDone, isTrue);
      expect(meter.windowBytes, 131072);
      expect(meter.windowMs, 0);
    });

    test('喂 3 秒窗口数据：mibPerSec == 窗口字节 / 1024² / 3（±0.01）', () {
      final meter = SpeedMeter()..onChunk(262144, 0); // 预热
      const chunk = 1024 * 1024;
      meter.onChunk(chunk, 1000);
      meter.onChunk(chunk, 2000);
      meter.onChunk(chunk, 3000);

      final sample = meter.sample()!;

      expect(sample.windowBytes, 3 * chunk);
      expect(sample.windowMs, 3000);
      expect(sample.mibPerSec, closeTo(3 * chunk / (1024 * 1024) / 3, 0.01));
      expect(sample.mibPerSec, closeTo(1.0, 0.01));
    });

    test('窗口不足 1 秒时按 1 秒计（避免几十毫秒窗口把结果放大几十倍）', () {
      final meter = SpeedMeter()..onChunk(262144, 0);
      meter.onChunk(1024 * 1024, 100); // 100ms 就读了 1 MiB

      final sample = meter.sample()!;

      expect(sample.windowMs, 1000);
      expect(sample.mibPerSec, closeTo(1.0, 0.01),
          reason: '1MiB / 1s = 1 MiB/s');
    });

    test('单块超过 64MiB 立即 reachedMaxBytes', () {
      final meter = SpeedMeter()..onChunk(262144, 0);

      expect(meter.reachedMaxBytes, isFalse);
      meter.onChunk(67108865, 10); // 64MiB + 1 字节
      expect(meter.reachedMaxBytes, isTrue);
    });

    test('窗口用满 3000ms 才 reachedBudget（差 1ms 不算）', () {
      final meter = SpeedMeter()..onChunk(262144, 0);

      meter.onChunk(1024, 2999);
      expect(meter.reachedBudget, isFalse);
      meter.onChunk(1024, 3000);
      expect(meter.reachedBudget, isTrue);
    });

    test('预热期间 reachedBudget / reachedMaxBytes 都是 false（不要提前 break）', () {
      final meter = SpeedMeter()..onChunk(262144 - 1, 9999);

      expect(meter.warmupDone, isFalse);
      expect(meter.reachedBudget, isFalse);
      expect(meter.reachedMaxBytes, isFalse);
    });

    test('bytes <= 0 的 chunk 被忽略（不污染首字节与窗口）', () {
      final meter = SpeedMeter()
        ..onChunk(0, 5)
        ..onChunk(-1, 6);

      expect(meter.total, 0);
      expect(meter.firstByteMs, -1);
    });
  });

  group('LinkProbeOutcome 语义（未测 ≠ 0）', () {
    test('成功：ok / latencyKnown / hasSpeed 都为真', () {
      const outcome = LinkProbeOutcome(
        ttfbMs: 123,
        speedMib: 8.5,
        elapsedMs: 3100,
      );

      expect(outcome.ok, isTrue);
      expect(outcome.latencyKnown, isTrue);
      expect(outcome.hasSpeed, isTrue);
    });

    test('预热未完成：有 TTFB、speedMib 为 null（不是 0.0）', () {
      const outcome = LinkProbeOutcome(
        ttfbMs: 88,
        speedMib: null,
        error: kProbeWarmupIncomplete,
        elapsedMs: 3200,
      );

      expect(outcome.latencyKnown, isTrue);
      expect(outcome.speedMib, isNull);
      expect(outcome.hasSpeed, isFalse, reason: '未测不能被当成「测出 0 速度」');
      expect(outcome.ok, isFalse);
    });

    test('失败：ttfb=-1，error 原文保留', () {
      final outcome = LinkProbeOutcome.failure('HTTP 404', 500);

      expect(outcome.ok, isFalse);
      expect(outcome.latencyKnown, isFalse);
      expect(outcome.error, 'HTTP 404');
    });

    test('取消：cancelled 为真且 ok 为假（不能算作可用）', () {
      final outcome = LinkProbeOutcome.cancelledAt(700);

      expect(outcome.cancelled, isTrue);
      expect(outcome.ok, isFalse);
      expect(outcome.error, isNull);
    });
  });

  group('humanizeProbeError 文案', () {
    test('SocketException 带原文，便于区分「连接被拒」与「超时」', () {
      final msg =
          humanizeProbeError(const SocketException('Connection refused'));

      expect(msg, contains('连接失败'));
      expect(msg, contains('Connection refused'));
    });

    test('TimeoutException 归一为「超时」', () {
      expect(humanizeProbeError(TimeoutException('slow')), '超时');
    });

    test('HandshakeException / HttpException 有明确前缀', () {
      expect(
        humanizeProbeError(const HandshakeException('bad cert')),
        contains('TLS 握手失败'),
      );
      expect(
        humanizeProbeError(const HttpException('bad chunk')),
        contains('HTTP 错误'),
      );
    });

    test('FormatException 归一为「地址非法」（probeUri 的失败会走到这里）', () {
      final msg = humanizeProbeError(const FormatException('测速地址无法解析'));

      expect(msg, contains('地址非法'));
      expect(msg, contains('测速地址无法解析'));
    });

    test('未知异常原样返回，不吞掉信息', () {
      expect(humanizeProbeError(StateError('boom')), contains('boom'));
    });
  });

  group('固定文案（UI 与单测共用，改动会同时失效）', () {
    test('没有读到数据 / 预热未完成', () {
      expect(kProbeNoData, '没有读到数据');
      expect(kProbeWarmupIncomplete, '预热未完成（3s 内读不满 256 KiB）');
    });

    test('默认测速地址的 е 是西里尔字母（必须走 punycode）', () {
      expect(kDefaultSpeedUrl.contains('е'), isTrue);
      expect(
          kDefaultSpeedUrl.codeUnitAt(kDefaultSpeedUrl.indexOf('е')), 0x0435);
    });
  });

  // -------------------------------------------------------------------------
  // 以下是**离线端到端**用例：用一个本地 `HttpServer` 扮演「本机 Xray 入站」。
  //
  // 为什么能这么测：Dart 的 `HttpClient` 在 `findProxy` 返回 `PROXY host:port`
  // 时，对 `http://` 目标会发 **absolute-form**（`GET http://host/x HTTP/1.1`）
  // 给代理，而 `HttpServer` 完全能解析并回包。于是「TTFB / 非 2xx / 连接被拒 /
  // 看门狗超时 / 吞吐窗口截断」全都不需要真机、不需要 xray 二进制就能断言。
  // （真机只用来验 `https://` 的 CONNECT 那一层，见 tool/smoke_probe.dart）
  // -------------------------------------------------------------------------

  group('LinkProbe.latency · TTFB（本地代理端到端）', () {
    test('延迟 300ms 才吐首字节：ttfbMs ≈ 300、error 为 null', () async {
      final inbound = await _FakeInbound.start(
        (req) => _respond(req, delayMs: 300, bodyBytes: 1024),
      );
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: 'http://probe.test/300.zip',
        localPort: inbound.port,
      );

      final outcome = await probe.latency();

      expect(outcome.error, isNull);
      expect(outcome.latencyKnown, isTrue);
      // 下界取 250ms 留抖动余量；上界防止把「建连」算成「首字节」
      expect(outcome.ttfbMs, greaterThanOrEqualTo(250));
      expect(outcome.ttfbMs, lessThan(5000));
      expect(outcome.ok, isTrue);
    });

    test('首字节时间是「第一个字节」而不是「响应头」：先发头再压 300ms 发体', () async {
      final inbound = await _FakeInbound.start((req) async {
        final resp = req.response;
        resp.statusCode = 200;
        resp.contentLength = 512;
        // 先把响应头刷出去
        await resp.flush();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        resp.add(List<int>.filled(512, 0x42));
        await resp.close();
      });
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: 'http://probe.test/300.zip',
        localPort: inbound.port,
      );

      final outcome = await probe.latency();

      expect(outcome.error, isNull);
      expect(
        outcome.ttfbMs,
        greaterThanOrEqualTo(250),
        reason: 'TTFB 必须量到 body 首字节，不能量到响应头',
      );
    });

    test('非 2xx：error == "HTTP 503"、ttfbMs == -1（不当成可用）', () async {
      final inbound = await _FakeInbound.start(
        (req) => _respond(req, status: 503, bodyBytes: 32),
      );
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: 'http://probe.test/300.zip',
        localPort: inbound.port,
      );

      final outcome = await probe.latency();

      expect(outcome.ttfbMs, -1);
      expect(outcome.error, 'HTTP 503');
      expect(outcome.ok, isFalse);
      expect(outcome.latencyKnown, isFalse);
    });

    test('2xx 但 body 为空：error == kProbeNoData（有响应没数据也是失败）', () async {
      final inbound = await _FakeInbound.start(
        (req) => _respond(req, bodyBytes: 0),
      );
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: 'http://probe.test/300.zip',
        localPort: inbound.port,
      );

      final outcome = await probe.latency();

      expect(outcome.error, kProbeNoData);
      expect(outcome.ttfbMs, -1);
    });

    test('连接失败（端口没人监听）：error 含「连接失败」，且文案里没有非 ASCII 主机名', () async {
      // 先占一个端口再立刻释放，保证这个端口确实没人监听
      final tmp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = tmp.port;
      await tmp.close();
      final probe = LinkProbe(
        speedUrl: 'https://е.eu.org/300.zip', // IDN：顺带验 K1 ③ 文案洁净
        localPort: deadPort,
      );

      final outcome = await probe.latency();

      expect(outcome.error, isNotNull);
      expect(outcome.error, contains('连接失败'));
      expect(outcome.ttfbMs, -1);
      // K1 ③：异常/日志里不允许出现非 ASCII 主机名（西里尔区段）
      expect(RegExp(r'[\u0400-\u04FF]').hasMatch(outcome.error!), isFalse);
      expect(outcome.error, isNot(contains('е.eu.org')));
    });

    test('对端挂住不响应：看门狗到点收尾（注入 200ms，不会等满 12s）', () async {
      final inbound = await _FakeInbound.start((req) async {
        // 永不回包，只等测试结束后被 force close
        await Future<void>.delayed(const Duration(seconds: 9));
      });
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: 'http://probe.test/300.zip',
        localPort: inbound.port,
        latencyTimeout: const Duration(milliseconds: 200),
      );

      final outcome = await probe.latency();

      expect(outcome.error, isNotNull, reason: '超时必须转成可见的失败原因');
      expect(
        outcome.elapsedMs,
        lessThan(3000),
        reason: '看门狗必须在 timeout 附近收尾，不能挂到 12s 口径',
      );
      expect(outcome.ok, isFalse);
    });

    test('IDN 测速地址：实际发出的主机名是 punycode（服务端收到的 Host 无西里尔字符）', () async {
      final seenHosts = <String>[];
      final inbound = await _FakeInbound.start((req) async {
        seenHosts.add(req.headers.value('host') ?? '');
        await _respond(req, bodyBytes: 256);
      });
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: 'https://е.eu.org/300.zip',
        localPort: inbound.port,
      );

      await probe.latency();

      expect(seenHosts, isNotEmpty);
      expect(seenHosts.first, startsWith('xn--e1a.eu.org'));
      expect(RegExp(r'^[\x00-\x7F]+$').hasMatch(seenHosts.first), isTrue);
    });
  });

  group('LinkProbe.speed · 吞吐窗口（本地代理端到端）', () {
    test('预热未完成（只发 100KiB 就断开）：speedMib 为 null + kProbeWarmupIncomplete',
        () async {
      final inbound = await _FakeInbound.start(
        (req) => _respond(req, bodyBytes: 100 * 1024),
      );
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: 'http://probe.test/300.zip',
        localPort: inbound.port,
      );

      final outcome = await probe.speed();

      expect(outcome.speedMib, isNull, reason: '未测必须是 null，不能是 0.0');
      expect(outcome.error, kProbeWarmupIncomplete);
      expect(outcome.hasSpeed, isFalse);
      expect(outcome.latencyKnown, isTrue, reason: '首字节已读到，延迟仍然有效');
    });

    test('未满 64MiB 就结束：按实际字节/实际耗时算，且不会被放大成天文数字', () async {
      // 预热 256KiB + 窗口 2MiB：真实耗时远小于 1s，故窗口按 minWindow=1s 兜底
      // → 期望 ≈ 2.0 MiB/s（允许慢机把实际窗口拉长到 1s 以上而略低）
      const afterWarmup = 2 * 1024 * 1024;
      final inbound = await _FakeInbound.start((req) async {
        final resp = req.response;
        resp.statusCode = 200;
        resp.contentLength = kWarmupBytes + afterWarmup;
        resp.add(List<int>.filled(kWarmupBytes, 0x41));
        await resp.flush();
        const chunk = 64 * 1024;
        for (var sent = 0; sent < afterWarmup; sent += chunk) {
          resp.add(List<int>.filled(chunk, 0x41));
          await resp.flush();
        }
        await resp.close();
      });
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: 'http://probe.test/300.zip',
        localPort: inbound.port,
      );

      final outcome = await probe.speed();

      expect(outcome.error, isNull);
      expect(outcome.speedMib, isNotNull);
      expect(outcome.hasSpeed, isTrue);
      final mib = outcome.speedMib!;
      expect(mib, greaterThan(0));
      expect(
        mib,
        lessThanOrEqualTo(2.5),
        reason: '2 MiB / 1s(兜底下限) ≈ 2.0 MiB/s；不能把窗口算成几毫秒而放大几十倍',
      );
      expect(outcome.ttfbMs, greaterThan(0));
    });

    test('刚好读满 3s 窗口就停：不会把整条 300.zip 读完（窗口截断生效）', () async {
      // 服务端持续以稳定节奏吐数据，明确远超 3s 窗口能读的量；
      // 断言：elapsed 落在窗口附近而不是把整条流读完
      final inbound = await _FakeInbound.start((req) async {
        final resp = req.response;
        resp.statusCode = 200;
        // 故意不设 contentLength：模拟「大文件」，靠客户端 break 取消订阅
        for (var i = 0; i < 400; i++) {
          resp.add(List<int>.filled(64 * 1024, 0x41));
          await resp.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await resp.close();
      });
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: 'http://probe.test/300.zip',
        localPort: inbound.port,
      );

      final outcome = await probe.speed();

      expect(outcome.error, isNull);
      expect(outcome.speedMib, isNotNull);
      expect(
        outcome.elapsedMs,
        lessThan(kBudgetMs + 4000),
        reason: '达到 3s 预算必须 break，不能把整条流读完',
      );
      expect(outcome.elapsedMs, greaterThanOrEqualTo(kBudgetMs - 500));
    });
  });
}

/// 一个「扮演本机 Xray 入站」的本地 HTTP 服务。
///
/// 只监听 loopback 的随机端口，测试结束时必须 [close]（用 `addTearDown`）。
class _FakeInbound {
  _FakeInbound._(this._server);

  final HttpServer _server;

  int get port => _server.port;

  static Future<_FakeInbound> start(
    Future<void> Function(HttpRequest request) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      // 单个请求的处理异常不能让整个测试挂死：吞掉后由断言暴露
      unawaited(handler(request).catchError((Object _) {}));
    });
    return _FakeInbound._(server);
  }

  Future<void> close() => _server.close(force: true);
}

/// 回一个固定状态的响应；[delayMs] 在**写 body 之前**，用来制造可测的 TTFB。
Future<void> _respond(
  HttpRequest request, {
  int status = 200,
  int delayMs = 0,
  int bodyBytes = 1024,
}) async {
  if (delayMs > 0) {
    await Future<void>.delayed(Duration(milliseconds: delayMs));
  }
  final resp = request.response;
  resp.statusCode = status;
  resp.contentLength = bodyBytes;
  if (bodyBytes > 0) {
    resp.add(List<int>.filled(bodyBytes, 0x41));
  }
  await resp.close();
}
