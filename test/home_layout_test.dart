import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/home.dart';

Widget _host(Widget child) => ChangeNotifierProvider<AppState>.value(
      value: AppState(),
      child: MaterialApp(home: child),
    );

/// 首页信息架构：主流程 2+1（01 获取数据 / 02 本地测试 / 03 结果通栏）+ 工具双列。
/// 这里守的是**入口齐全、窄屏不溢出、可滚到底**，版式细节交给预览图。
void main() {
  testWidgets('首页窄屏不溢出：入口齐全、无线路卡位', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const HomeShell()));
    await tester.pump();

    // 标题与主流程
    expect(find.text('cytest'), findsOneWidget);
    expect(find.text('主流程'), findsOneWidget);
    expect(find.text('获取数据'), findsOneWidget);
    expect(find.text('本地测试'), findsOneWidget);

    // 步骤徽章（01/02/03）
    for (final badge in ['01', '02', '03']) {
      expect(find.text(badge), findsOneWidget, reason: '徽章 $badge');
    }

    // 工具在窄屏要能滚出来（ListView 懒构建）
    await tester.scrollUntilVisible(find.text('远程执行'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('工具'), findsOneWidget);
    expect(find.text('结果'), findsOneWidget);
    expect(find.text('记录'), findsOneWidget);
    expect(find.text('远程执行'), findsOneWidget);

    // 线路配置仍在设置里，首页不该出现
    expect(find.text('线路与代理'), findsNothing);

    // 溢出会以异常形式抛出
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页长屏可滚动到底：最后一个入口能滚进屏幕', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const HomeShell()));
    await tester.pump();

    await tester.scrollUntilVisible(
      find.text('远程执行'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('远程执行'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
