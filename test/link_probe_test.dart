import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/link_probe.dart';

void main() {
  group('SpeedMeter 预热与窗口（常量口径）', () {
    test('常量就是那四个：256KiB / 3000ms / 64MiB / 1000ms', () {
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
        latencyUrl: 'http://probe.test/300.zip',
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
        latencyUrl: 'http://probe.test/300.zip',
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
        latencyUrl: 'http://probe.test/300.zip',
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
        latencyUrl: 'http://probe.test/300.zip',
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
        latencyUrl: 'https://е.eu.org/300.zip',
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
        latencyUrl: 'http://probe.test/300.zip',
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
        latencyUrl: 'https://е.eu.org/300.zip',
        localPort: inbound.port,
      );

      await probe.latency();

      expect(seenHosts, isNotEmpty);
      expect(seenHosts.first, startsWith('xn--e1a.eu.org'));
      expect(RegExp(r'^[\x00-\x7F]+$').hasMatch(seenHosts.first), isTrue);
    });
  });

  group('延迟死线与候选端点（B 方案）', () {
    test('常量口径：死线 5s、最多 3 次尝试、候选链首项就是默认端点', () {
      expect(
        kLatencyTimeout,
        const Duration(seconds: 5),
        reason: '12s × 3 个候选会把整轮拖到 36s，用户会以为卡死',
      );
      expect(kLatencyMaxAttempts, 3, reason: '首选 + 2 次切换');
      expect(kLatencyFallbackUrls.first, kDefaultLatencyUrl,
          reason: '兜底链首项必须与默认端点同一个值（引用同一常量，别复制字面量）');
      expect(kLatencyFallbackUrls.length, 2);
      expect(
        kSpeedTimeout,
        const Duration(seconds: 25),
        reason: '速度阶段是 3s 窗口 + 慢启动 + 建连，不能跟着延迟一起缩',
      );
      expect(
        kConnectTimeout,
        const Duration(seconds: 8),
        reason: '建连超时是原版设定，本轮不动（死线先到由 watchdog 负责）',
      );
    });

    test('看门狗到点收尾时，失败原因可读：恰好是「超时」，不是 cancelled、不是空串', () async {
      final inbound = await _FakeInbound.start((req) async {
        // 接了不回包：模拟 DNS 卡死 / 端点黑洞
        await Future<void>.delayed(const Duration(seconds: 9));
      });
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: 'http://probe.test/300.zip',
        latencyUrl: 'http://probe.test/generate_204',
        localPort: inbound.port,
        latencyTimeout: const Duration(milliseconds: 200),
      );

      final outcome = await probe.latency();

      expect(
        outcome.error,
        kProbeTimeout,
        reason: '5s 死线比 8s 建连超时短，先到的是 watchdog；'
            '它掐断在途请求抛的是 HttpException（「连接被中断」），'
            '必须被翻译成「超时」，否则用户读不懂',
      );
      expect(outcome.error, isNotEmpty);
      expect(outcome.cancelled, isFalse, reason: '超时不是取消，两者不能混');
      expect(outcome.ok, isFalse);
      expect(outcome.elapsedMs, lessThan(3000), reason: '看门狗必须按注入的死线收尾');
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
        latencyUrl: 'http://probe.test/300.zip',
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
        latencyUrl: 'http://probe.test/300.zip',
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
        latencyUrl: 'http://probe.test/300.zip',
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

  // -------------------------------------------------------------------------
  // Bug B：延迟读数远大于 v2rayN 的「真连接延迟」。
  //
  // 修复前的口径：拿**测速**地址（300.zip 大文件）发请求、followRedirects=true、
  // 以 body 首字节当 TTFB。三条叠加：跨主机跳转会重新 _getConnection（第二套
  // CONNECT/TLS/请求），大文件端点的首字节被服务端缓冲推迟，于是读数天然翻倍。
  // 以下用例把这三条钉死。
  // -------------------------------------------------------------------------
  group('LinkProbe.latency · 与 v2rayN 可比的延迟口径（Bug B）', () {
    test('默认延迟端点是 204 小端点，且与测速端点分开（两条口径不许混）', () {
      expect(kDefaultLatencyUrl, contains('generate_204'));
      expect(kDefaultLatencyUrl, isNot(contains('300.zip')));
      expect(kDefaultSpeedUrl, contains('300.zip'));

      final probe = LinkProbe(localPort: 1234);

      // 延迟：小端点、无 body、无跳转
      expect(probe.latencyUri.host, 'cp.cloudflare.com');
      expect(probe.latencyUri.path, '/generate_204');
      // 速度：必须继续用大文件端点（3s 窗口要读得满）
      expect(probe.uri.host, 'xn--e1a.eu.org');
      expect(probe.uri.path, '/300.zip');
    });

    test('不跟随跳转：302 只发一次请求，且记为「可达」（redirects == 0）', () async {
      final requests = <String>[];
      final inbound = await _FakeInbound.start((req) async {
        requests.add(req.uri.toString());
        final resp = req.response;
        resp.statusCode = HttpStatus.found; // 302
        resp.headers.set(
          HttpHeaders.locationHeader,
          'http://other-host.test/generate_204',
        );
        resp.contentLength = 0;
        await resp.close();
      });
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: 'http://probe.test/300.zip',
        latencyUrl: 'http://probe.test/300.zip',
        localPort: inbound.port,
      );

      final outcome = await probe.latency();

      expect(
        requests.length,
        1,
        reason: 'followRedirects=true 时 SDK 会为 Location 重新建连'
            '（_http/http_impl.dart:693 → :3026）再发一次请求，'
            '延迟读数会白白多一整套 CONNECT+TLS',
      );
      expect(outcome.ok, isTrue, reason: '跳转只说明目标站点策略，不说明线路不通');
      expect(outcome.error, isNull);
      expect(outcome.ttfbMs, greaterThanOrEqualTo(0));
      expect(outcome.timings, isNotNull);
      expect(outcome.timings!.redirects, 0);
    });

    test('204 No Content：TTFB 取响应头时刻，不能判成「没有读到数据」', () async {
      final inbound = await _FakeInbound.start((req) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final resp = req.response;
        resp.statusCode = HttpStatus.noContent;
        await resp.close();
      });
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: 'http://probe.test/300.zip',
        latencyUrl: 'http://probe.test/300.zip',
        localPort: inbound.port,
      );

      final outcome = await probe.latency();

      expect(
        outcome.error,
        isNull,
        reason: '默认延迟端点就是 generate_204（天生无 body），'
            '把它判成 kProbeNoData 会让所有节点整批失败',
      );
      expect(outcome.ok, isTrue);
      expect(outcome.ttfbMs, greaterThanOrEqualTo(150));
      expect(outcome.ttfbMs, lessThan(5000));
      expect(outcome.timings!.headerMs, greaterThanOrEqualTo(150));
      expect(outcome.timings!.firstByteMs, -1, reason: '204 没有 body，首字节记为未知');
    });

    test('分项计时：能把「建连」与「服务端压着不回」分开看出来', () async {
      // 服务端接到请求后先压 200ms 才写任何东西：这段延迟必须落在
      // headerMs 上，而不是被算进 connectMs —— 否则日志里就分不清
      // 「隧道慢」和「对端慢」，排障方向完全相反。
      final inbound = await _FakeInbound.start((req) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await _respond(req, bodyBytes: 512);
      });
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: 'http://probe.test/300.zip',
        latencyUrl: 'http://probe.test/300.zip',
        localPort: inbound.port,
      );

      final outcome = await probe.latency();
      final timings = outcome.timings!;

      expect(timings.connectMs, greaterThanOrEqualTo(0), reason: '建连必须被计时');
      expect(
        timings.headerMs,
        greaterThanOrEqualTo(150),
        reason: '这 200ms 是「对端压着不回」，必须落在响应头这一段',
      );
      expect(
        timings.headerMs - timings.connectMs,
        greaterThanOrEqualTo(150),
        reason: '本机入站的建连是毫秒级，差值必须几乎全部来自对端等待',
      );
      expect(timings.firstByteMs, greaterThanOrEqualTo(timings.headerMs));
      expect(outcome.ttfbMs, timings.firstByteMs,
          reason: 'TTFB 仍以首字节为准（有 body 时）');
    });

    test('4xx/5xx 仍然是失败（放宽 3xx 不等于放宽真错）', () async {
      final inbound = await _FakeInbound.start(
        (req) => _respond(req, status: 404, bodyBytes: 16),
      );
      addTearDown(inbound.close);
      final probe = LinkProbe(
        speedUrl: 'http://probe.test/300.zip',
        latencyUrl: 'http://probe.test/300.zip',
        localPort: inbound.port,
      );

      final outcome = await probe.latency();

      expect(outcome.error, 'HTTP 404');
      expect(outcome.ok, isFalse);
      expect(outcome.timings, isNotNull, reason: '失败也要留下分项计时，便于排障');
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
