import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/home.dart';

Widget _host(Widget child) => ChangeNotifierProvider<AppState>.value(
      value: AppState(),
      child: MaterialApp(home: child),
    );

/// 首页把 6 个入口重排成「主流程 3 步 + 工具 2 项」，线路配置移入设置。
/// 三条横排卡片在窄屏很容易溢出，这里用 360dp 兜住。
void main() {
  testWidgets('首页窄屏不溢出：主流程 3 步 + 工具 2 项，线路不再占卡位',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const HomeShell()));
    await tester.pump();

    // 主流程：序号 + 标题
    for (final step in ['1', '2', '3']) {
      expect(find.text(step), findsOneWidget, reason: '步骤 $step 序号');
    }
    expect(find.text('获取数据'), findsOneWidget);
    expect(find.text('本地测试'), findsOneWidget);
    expect(find.text('结果'), findsOneWidget);

    // 工具
    expect(find.text('记录'), findsOneWidget);
    expect(find.text('远程执行'), findsOneWidget);

    // 线路配置已移入设置，首页不再有该卡位
    expect(find.text('线路与代理'), findsNothing);

    // 配置指引可点（去设置）
    expect(find.textContaining('在「设置」里配置'), findsOneWidget);

    // 没有溢出（overflow 会以异常形式抛出，这里断言无此类异常）
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置页包含线路与 proxyip 配置，且不展示 proxyip 内容', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const HomeShell()));
    await tester.pump();
    // 切到设置 tab
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    expect(find.text('线路与代理'), findsOneWidget);
    expect(find.text('VLESS 链接'), findsOneWidget);
    expect(find.text('加载文件'), findsOneWidget);
    expect(find.textContaining('已加载'), findsOneWidget);
    // 只显示条目数，不给可编辑的 proxyip 文本框
    expect(find.text('每行 ip:port，用于替换 ws 路径里的回源地址'), findsNothing);

    expect(tester.takeException(), isNull);
  });
}
