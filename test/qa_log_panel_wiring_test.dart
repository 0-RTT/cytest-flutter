// QA 独立审计（严过关）· 接线验证之二：LogPanel 是否真的把 `state.logs` 画出来。
//
// 为什么单独一个文件：`flutter_test` 一旦在**同一个文件**里出现 `testWidgets`，
// 整个文件的真实 HTTP 请求都会被 binding 换成一个恒返回 400 的假客户端
// （"all HTTP requests will return status code 400"）。本文件只做 UI 断言，
// 真实 socket 的用例留在 `qa_link_audit_test.dart`，两者不能混在一个文件里。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:cytest/data/link_test.dart';
import 'package:cytest/data/vless.dart';
import 'package:cytest/data/xray.dart';
import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/pages/vless_test_page.dart';

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

/// 永不 bind 真实端口的端口池（本文件只验 UI，不跑测速轮次）。
class _StaticPool extends PortPool {
  @override
  Future<PortPick> pick(int n) async =>
      PortPick(ports: const <int>[], missing: n);
}

const String _template =
    'vless://8b1c2d3e-4f5a-4b6c-8d9e-0a1b2c3d4e5f@1.2.3.4:443'
    '?encryption=none&security=tls&type=ws#test';

void main() {
  testWidgets('LogPanel 渲染 state.logs：分项计时行必须出现在「测速日志」卡片里', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // 注入 runner + 不 bind 任何端口的端口池：widget 用例不该触碰默认
    // PortPool（20000~20500 逐个 bind），否则并发跑全量时会与别的测试文件撞端口。
    final state = AppState(
      runner: LinkTestRunner(
        speedUrl: 'http://speed.test/300.zip',
        latencyUrl: 'http://speed.test/generate_204',
        xray: _FakeXrayProc(),
        pool: _StaticPool(),
      ),
    )..settings.vlessLinks = const <String>[_template];
    // 这一行就是 `LinkTestRunner._logOutcome` 的实际拼接格式（分行用 · 连接）
    state.pushLog('· 延迟 节点A · ttfb=21ms · 耗时=25ms · '
        '建连=3 响应头=21 首字节=21 跳转=0');

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(
          home: VlessTestPage(
            targets: <String>['1.2.3.4:443'],
            template: _template,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.textContaining('建连=3 响应头=21 首字节=21 跳转=0'),
      findsOneWidget,
      reason: 'LogPanel 必须真的把分项计时画出来，而不是只存在 state.logs 里',
    );
  });
}
