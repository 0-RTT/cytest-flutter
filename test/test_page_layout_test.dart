import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/pages/remote_page.dart';
import 'package:cytest/ui/pages/test_page.dart';

/// 真实 Censys 响应结构：候选来自 `results.hits[].host.ip` + `.port`。
const _bigJson =
    '{"pageLimitMessage":"Register to unlock","results":{"total_hits":3,'
    '"hits":[{"host":{"ip":"1.1.1.1","port":443}},'
    '{"host":{"ip":"2.2.2.2","port":8443}},'
    '{"host":{"ip":"3.3.3.3","port":2053}}]}}';

Widget _host(Widget child, {AppState? state}) => MaterialApp(
      home: ChangeNotifierProvider<AppState>(
        create: (_) => state ?? AppState(),
        child: child,
      ),
    );

/// 布局测试统一关掉 autoStart：验的是页面结构，不该真的去起引擎进程。
Widget _page({AppState? state}) => _host(
      const TestPage(initialInput: _bigJson, autoStart: false),
      state: state,
    );

void main() {
  group('TestPage · 本地记录选择', () {
    testWidgets('抓取 JSON 只显示摘要，不铺在输入区', (tester) async {
      await tester.pumpWidget(_page());
      await tester.pump();

      // 核心诉求：页面上看不到抓取内容本身
      expect(find.textContaining('pageLimitMessage'), findsNothing);
      expect(find.textContaining('Register to unlock'), findsNothing);

      // 一行摘要：来源 + 候选数
      expect(find.textContaining('来自抓取结果'), findsOneWidget);
      expect(find.textContaining('3 个候选'), findsOneWidget);
    });

    testWidgets('页面不再有三个测试按钮：选择即开始', (tester) async {
      await tester.pumpWidget(_page());
      await tester.pump();

      expect(find.text('延迟测试'), findsNothing);
      expect(find.text('速度测试'), findsNothing);
      expect(find.text('一键测试'), findsNothing);
      expect(find.text('运行中…'), findsNothing);

      // 源码层：`_start` 已无 mode 参数，只剩唯一入口
      final src = File('lib/ui/pages/test_page.dart').readAsStringSync();
      expect(src, isNot(contains("_start('latency')")));
      expect(src, isNot(contains("_start('speed')")));
      expect(src, isNot(contains("_start('both')")));
      expect(src, contains("runLocal(mode: 'both'"),
          reason: '唯一的入口必须是一键测试（指纹→延迟→速度）');
    });

    testWidgets('头部统计卡已移除：没有「候选总量 / 当前阶段 / 可用」', (tester) async {
      await tester.pumpWidget(_page());
      await tester.pump();

      expect(find.text('候选总量'), findsNothing);
      expect(find.text('当前阶段'), findsNothing);
      expect(find.text('可用'), findsNothing);
      expect(find.text('进度'), findsNothing, reason: '进度卡已并入日志卡片');
    });

    testWidgets('没有数据时提示「选择记录」', (tester) async {
      await tester.pumpWidget(_host(const TestPage()));
      await tester.pump();

      expect(find.text('选择记录'), findsOneWidget);
    });

    testWidgets('清空后回到未选择状态', (tester) async {
      await tester.pumpWidget(_page());
      await tester.pump();

      await tester.tap(find.text('清空'));
      await tester.pump();

      expect(find.text('选择记录'), findsOneWidget);
    });

    testWidgets('运行中禁止换记录与清空', (tester) async {
      final state = AppState()..running = true;
      await tester.pumpWidget(_page(state: state));
      await tester.pump();

      // 换记录 / 清空要锁住，否则中途换输入会让进度和结果对不上
      final picker = find.ancestor(
        of: find.textContaining('来自抓取结果'),
        matching: find.byType(InkWell),
      );
      expect(tester.widget<InkWell>(picker.first).onTap, isNull);
      expect(
        tester.widget<TextButton>(find.widgetWithText(TextButton, '清空')).onPressed,
        isNull,
      );
    });

    testWidgets('不再提供「粘贴候选数据」入口：整页没有任何可编辑输入框', (tester) async {
      await tester.pumpWidget(_page());
      await tester.pump();

      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('粘贴'), findsNothing);
      expect(find.textContaining('完整三阶段'), findsNothing);
      expect(find.textContaining('候选数据'), findsNothing);
    });

    // 源码级钉住：这三样东西被删掉后被误加回来时，上面的 UI 断言未必抓得到
    // （弹层是懒构建的），所以直接扫源码。
    test('test_page.dart 不再残留旧入口', () {
      final src = File('lib/ui/pages/test_page.dart').readAsStringSync();
      expect(src, isNot(contains('_InputEditorSheet')));
      expect(src, isNot(contains('完整三阶段')));
      expect(src, isNot(contains('粘贴候选数据')));
      expect(src, isNot(contains('_progressCard')),
          reason: '进度卡整体已删除，进度条改由 LogPanel 画');
    });

    testWidgets('日志有内容时渲染在页面上', (tester) async {
      final state = AppState();
      state.logs.addAll(const [
        '[速度 1/2] 1.1.1.1:443 正常',
        '阶段=body err=响应体为空 (HTTP 403)',
      ]);
      await tester.pumpWidget(_host(const TestPage(), state: state));
      await tester.pump();

      expect(find.textContaining('[速度 1/2]'), findsOneWidget);
      expect(find.text('2 行'), findsOneWidget);
      expect(find.byTooltip('跳到最新'), findsOneWidget);
      expect(find.byTooltip('复制日志'), findsOneWidget);
    });

    testWidgets('进度条画在日志卡片内部，并显示计数', (tester) async {
      final state = AppState()
        ..progressCur = 12
        ..progressTotal = 553;
      await tester.pumpWidget(_host(const TestPage(), state: state));
      await tester.pump();

      final card = find.byKey(const ValueKey('test_page_log_card'));
      final bar = find.descendant(
        of: card,
        matching: find.byType(LinearProgressIndicator),
      );
      expect(bar, findsOneWidget, reason: '进度条必须是日志卡片的后代');
      expect(find.text('12 / 553'), findsOneWidget);
      // 页面上不能有第二根进度条（旧进度卡已删）
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('小屏 + 满载输入时日志区仍占屏高四分之一以上且不越屏', (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final state = AppState();
      state.logs.addAll(List.generate(40, (i) => '[速度 ${i + 1}/40] 失败'));
      await tester.pumpWidget(_page(state: state));
      await tester.pump();

      final card = find.byKey(const ValueKey('test_page_log_card'));
      final size = tester.getSize(card);
      final topLeft = tester.getTopLeft(card);
      // 640 逻辑像素高的小屏：日志至少 160px，且底部不越屏
      expect(size.height, greaterThan(160));
      // 「包底」：卡片底边与屏幕底至少留 10px
      expect(640 - (topLeft.dy + size.height), greaterThanOrEqualTo(10));
    });
  });

  group('RemotePage · 输出模块', () {
    testWidgets('远端输出面板有包底、独占剩余高度', (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(const RemotePage()));
      await tester.pump();

      final panel = find.byKey(const ValueKey('remote_output_panel'));
      final size = tester.getSize(panel);
      final topLeft = tester.getTopLeft(panel);
      expect(size.height, greaterThan(100));
      expect(640 - (topLeft.dy + size.height), greaterThanOrEqualTo(10));
      expect(find.text('未执行'), findsOneWidget);
      expect(find.byTooltip('复制日志'), findsOneWidget);
    });
  });
}
