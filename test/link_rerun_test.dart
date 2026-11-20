// Bug A 回归：「取消 → 再测」必须成功。
//
// 事故根因（修复前的代码）：`LinkTestRunner.cancel()` 会 `drain()` 两个并发闸门，
// 而 drain 是**永久**的（此后每次 acquire 都抛 CancelledException，只有 reopen 能
// 恢复）；闸门又是 runner 的实例字段，runner 在 AppState 里是 `late final` 单例、
// 跨轮复用。于是取消一轮之后，第二轮每个探测都在 acquire 处被判 cancelled，
// 用户看到的就是「整批条目立刻变成已取消」。
//
// 为什么必须放在独立文件里：本文件**只使用修复前就存在的公开 API**
// （run / cancel / LinkTestMode / ProbeState）。这样把 `lib/` 回退到修复前
// （`git stash push -- lib`）时它仍然能编译，从而真实地证明这条回归测试
// **在修复前是失败的**，而不是一条恒真断言。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/link_probe.dart';
import 'package:cytest/data/link_test.dart';
import 'package:cytest/data/vless.dart';
import 'package:cytest/data/xray.dart';

/// 延迟端点：204 小端点（无 body、无跳转）。
const String _latencyUrl = 'http://speed.test/generate_204';

/// 速度端点：大文件。
const String _speedUrl = 'http://speed.test/300.zip';

/// 造一条最小可用 vless（只填 runner/Vless.tryParse 会读的字段）。
String _link(String host, int port) => 'vless://uuid-$port@$host:$port'
    '?type=ws&security=tls&sni=$host&path=%2Fws';

/// 可控的批量启动器（真 xray 二进制在桌面跑不了）。
class _FakeXray implements BatchXray {
  _FakeXray({XrayMode initialMode = XrayMode.none}) : mode = initialMode;

  @override
  XrayMode mode;

  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<String?> startBatch(List<(Vless, int)> nodes) async {
    startCalls++;
    // 与真实 XrayProc.startBatch 一致：第一行就 stop()（串行互斥）。
    await stop();
    mode = XrayMode.batch;
    return null;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    mode = XrayMode.none;
  }
}

/// 按**调用轮次**给端口：第 N 次 `pick` 返回第 N 个端口。
///
/// 这条回归需要两轮指向不同的本地服务（第一轮必须能挂住、第二轮必须能回包），
/// 所以不能用固定端口的池子。只用单节点场景，`missing` 直接按 n-1 算。
class _ScriptedPool extends PortPool {
  _ScriptedPool(this._ports);

  final List<int> _ports;
  int calls = 0;

  @override
  Future<PortPick> pick(int n) async {
    final index = calls < _ports.length ? calls : _ports.length - 1;
    calls++;
    final ports = <int>[_ports[index]];
    final taken = ports.take(n).toList(growable: false);
    return PortPick(ports: taken, missing: n - taken.length);
  }
}

/// 「接了但永不回包」的服务：用来把第一轮卡在延迟阶段，好让我们有时间取消。
Future<HttpServer> _hang() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((_) {
    // 故意不响应：连接保持打开，直到客户端 cancel() 里 close(force: true)
  });
  return server;
}

/// 「按路径分流」的服务：`generate_204` → 204（延迟端点的等价物），
/// 其余 → 200 + 256KiB 预热 + 2MiB 窗口的大 body（速度端点的等价物）。
Future<HttpServer> _serveLatencyAndSpeed() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final response = request.response;
    if (request.uri.path.contains('generate_204')) {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }
    const total = kWarmupBytes + 2 * 1024 * 1024;
    response.statusCode = 200;
    response.contentLength = total;
    response.add(List<int>.filled(total, 0x41));
    await response.close();
  });
  return server;
}

void main() {
  group('Bug A：同一 runner 连续多轮（取消 → 重测）', () {
    test('取消后再测（auto，两个闸门都被 drain 过）：第二轮必须派发探测并拿到 done', () async {
      final hang = await _hang();
      final serve = await _serveLatencyAndSpeed();
      addTearDown(() async {
        await hang.close(force: true);
        await serve.close(force: true);
      });

      var probeCalls = 0;
      final xray = _FakeXray();
      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: xray,
        pool: _ScriptedPool(<int>[hang.port, serve.port]),
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

      // ---- 第一轮：挂住 → 取消（cancel 会 drain 掉延迟与速度两个闸门）----
      final first = runner.run(<String>[_link('a.example', 443)]);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(probeCalls, 1, reason: '第一轮必须真的发出了一个延迟探测');

      await runner.cancel();
      final firstRun = await first;
      expect(firstRun.results.single.state, ProbeState.cancelled);
      expect(runner.running, isFalse, reason: '第一轮收尾后 running 必须归位');

      // ---- 第二轮：修复前这里整批立刻变 cancelled（闸门仍是 drained）----
      final secondRun = await runner.run(<String>[_link('a.example', 443)]);

      expect(
        probeCalls,
        3,
        reason: '第二轮必须重新派发探测（延迟 1 个 + 速度 1 个）；'
            '若闸门没 reopen，这里会停在 1',
      );
      final result = secondRun.results.single;
      expect(result.state, ProbeState.done, reason: '第二轮必须是 done，不是 cancelled');
      expect(result.latencyKnown, isTrue);
      expect(
        result.speedMib,
        isNotNull,
        reason: '速度闸门也必须已恢复，否则速度阶段会被判 cancelled（speedMib 为 null）',
      );
      expect(xray.startCalls, 2, reason: '两轮各自起一次批量进程');
    });

    test('取消后立刻再点开始（不等第一轮收尾）：不能命中「上一次测速还在进行」', () async {
      final hang = await _hang();
      final serve = await _serveLatencyAndSpeed();
      addTearDown(() async {
        await hang.close(force: true);
        await serve.close(force: true);
      });

      final runner = LinkTestRunner(
        speedUrl: _speedUrl,
        latencyUrl: _latencyUrl,
        xray: _FakeXray(),
        pool: _ScriptedPool(<int>[hang.port, serve.port]),
        probeFactory: (speedUrl, latencyUrl, port) => LinkProbe(
          speedUrl: speedUrl,
          latencyUrl: latencyUrl,
          localPort: port,
          latencyTimeout: const Duration(seconds: 10),
        ),
      );

      final first = runner.run(<String>[_link('a.example', 443)]);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // 用户手速：点了「取消」随即点「开始」，中间不等第一轮 unwind。
      final cancelling = runner.cancel();
      final second = runner.run(<String>[_link('a.example', 443)]);

      await cancelling;
      final firstRun = await first;
      expect(firstRun.results.single.state, ProbeState.cancelled);

      final secondRun = await second;
      expect(
        secondRun.results.single.state,
        ProbeState.done,
        reason: '上一轮已被取消时应当「等它收尾再开新轮」，而不是抛「还在进行」',
      );
      expect(secondRun.results.single.latencyKnown, isTrue);
    });
  });
}
