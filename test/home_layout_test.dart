import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/home.dart';

Widget _host(Widget child) => ChangeNotifierProvider<AppState>.value(
      value: AppState(),
      child: MaterialApp(home: child),
    );

/// 首页信息架构：Bento 便当盒（可用节点 / 最低延迟 / 峰值速率）+ 主流程 3 步 +
/// 工具 2 项。这里守住的是**内容与不溢出**，不是像素位置 —— 版式可以改，
/// 但入口不能丢、窄屏不能炸。
void main() {
  testWidgets('首页窄屏不溢出：入口齐全、无线路卡位', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const HomeShell()));
    await tester.pump();

    // Bento 三块指标
    expect(find.text('可用节点'), findsOneWidget);
    expect(find.text('最低延迟'), findsOneWidget);
    expect(find.text('峰值速率'), findsOneWidget);

    // 主操作在首屏可见
    expect(find.text('开始本地测试'), findsOneWidget);

    // 分组列表在窄屏要能滚出来（ListView 懒构建，屏幕外的先不在树上）
    await tester.scrollUntilVisible(find.text('远程执行'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('主流程'), findsOneWidget);
    expect(find.text('工具'), findsOneWidget);
    expect(find.text('获取数据'), findsOneWidget);
    expect(find.text('本地测试'), findsOneWidget);
    expect(find.text('结果'), findsOneWidget);
    expect(find.text('记录'), findsOneWidget);
    expect(find.text('远程执行'), findsOneWidget);

    // 线路配置仍在设置里，首页不该再出现这块
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

    // 内容比一屏长（Bento + 按钮 + 两组列表），要能滚到底部
    await tester.scrollUntilVisible(
      find.text('远程执行'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('远程执行'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
