import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/pages/test_page.dart';

const _bigJson =
    '{"pageLimitMessage":"Register to unlock","results":{"total_hits":89,'
    '"hits":[{"host":"1.1.1.1","ip":"1.1.1.1"},'
    '{"host":"2.2.2.2","ip":"2.2.2.2"},'
    '{"host":"3.3.3.3","ip":"3.3.3.3"}]}}';

Widget _host(Widget child, {AppState? state}) => MaterialApp(
      home: ChangeNotifierProvider<AppState>(
        create: (_) => state ?? AppState(),
        child: child,
      ),
    );

void main() {
  group('TestPage · 布局重设计', () {
    testWidgets('大段抓取 JSON 只显示摘要，不铺在输入区', (tester) async {
      await tester.pumpWidget(_host(const TestPage(initialInput: _bigJson)));
      await tester.pump();

      // 核心诉求：页面上看不到抓取内容本身（原先 6 行 TextField 会被撑满）
      expect(find.textContaining('pageLimitMessage'), findsNothing);
      expect(find.textContaining('Register to unlock'), findsNothing);

      // 只留一行摘要，候选数来自 results.hits 而不是文本行数
      expect(find.textContaining('3 个候选'), findsOneWidget);
      expect(find.textContaining(' KB'), findsNothing);
      expect(find.textContaining(' B'), findsOneWidget);

      // 仍然能一眼看出这是输入区，且能开始测试
      expect(find.text('输入'), findsOneWidget);
      expect(find.text('开始测试'), findsOneWidget);
    });

    testWidgets('空输入显示引导，开始按钮不可用', (tester) async {
      await tester.pumpWidget(_host(const TestPage()));
      await tester.pump();

      expect(find.text('点击粘贴候选数据'), findsOneWidget);
      final start = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '开始测试'),
      );
      expect(start.onPressed, isNull);
    });

    testWidgets('点摘要打开编辑层，保存后摘要更新且主页面仍不铺全文', (tester) async {
      await tester.pumpWidget(_host(const TestPage(initialInput: _bigJson)));
      await tester.pump();

      await tester.tap(find.textContaining('3 个候选'));
      await tester.pumpAndSettle();

      // 编辑层里的 TextField 才有全文
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(
        find.byType(TextField),
        '{"results":{"hits":[{"ip":"9.9.9.9"}]}}',
      );
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 个候选'), findsOneWidget);
      expect(find.textContaining('pageLimitMessage'), findsNothing);
    });

    testWidgets('日志有内容时渲染在页面上（不再藏在外层滚动的底部小盒）',
        (tester) async {
      final state = AppState();
      state.logs.addAll(const [
        '[速度 1/2] 1.1.1.1:443 正常',
        '阶段=body err=响应体为空 (HTTP 403)',
      ]);
      await tester.pumpWidget(_host(const TestPage(), state: state));
      await tester.pump();

      expect(find.textContaining('[速度 1/2]'), findsOneWidget);
      expect(find.text('2 行'), findsOneWidget);
      // 日志工具按钮：跳到最新 + 复制
      expect(find.byTooltip('跳到最新'), findsOneWidget);
      expect(find.byTooltip('复制日志'), findsOneWidget);
    });

    testWidgets('小屏 + 满载输入时日志区仍占屏高四分之一以上且不越屏', (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final state = AppState();
      state.logs.addAll(List.generate(40, (i) => '[速度 ${i + 1}/40] 失败'));
      await tester.pumpWidget(
        _host(const TestPage(initialInput: _bigJson), state: state),
      );
      await tester.pump();

      final card = find.byKey(const ValueKey('test_page_log_card'));
      final size = tester.getSize(card);
      final topLeft = tester.getTopLeft(card);
      // 640 逻辑像素高的小屏：日志至少 160px，且底部不越屏
      expect(size.height, greaterThan(160));
      expect(topLeft.dy + size.height, lessThanOrEqualTo(641));
    });
  });
}
