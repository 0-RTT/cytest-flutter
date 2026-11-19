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

    // 内容不变：主流程三张步骤卡（带序号）+ 工具两项
    for (final step in ['1', '2', '3']) {
      expect(find.text(step), findsOneWidget, reason: '步骤 $step 序号');
    }
    expect(find.text('主流程'), findsOneWidget);
    expect(find.text('工具'), findsOneWidget);
    expect(find.text('获取数据'), findsOneWidget);
    expect(find.text('本地测试'), findsOneWidget);
    expect(find.text('结果'), findsOneWidget);

    // 工具
    expect(find.text('记录'), findsOneWidget);
    expect(find.text('远程执行'), findsOneWidget);

    // 线路配置已移入设置，首页不再有该卡位
    expect(find.text('线路与代理'), findsNothing);

    // 底部那条「…在『设置』里配置」的指引已删除：它与设置页重复，
    // 底部导航本来就有「设置」入口，再挂一条是同一件事的第二个说法。
    expect(find.textContaining('在「设置」里配置'), findsNothing);

    // 没有溢出（overflow 会以异常形式抛出，这里断言无此类异常）
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页高屏垂直居中：上下留白均等，不再上挤下空', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const HomeShell()));
    await tester.pump();

    // 内容块上沿 = 「主流程」标签，下沿 = 最后一行「远程执行」
    final top = tester.getRect(find.text('主流程')).top;
    final bottom = tester.getRect(find.text('远程执行')).bottom;
    // 可用区域：AppBar 下沿 ~ 底部导航上沿
    final appBarBottom = tester.getRect(find.byType(AppBar)).bottom;
    final navTop = tester.getRect(find.byType(NavigationBar)).top;

    final gapTop = top - appBarBottom;
    final gapBottom = navTop - bottom;

    // 居中意味着两侧留白接近（含标签/内边距的固有偏差，给 40px 容差）。
    expect((gapTop - gapBottom).abs(), lessThan(40),
        reason: '上下留白应接近：上 $gapTop / 下 $gapBottom');
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

    // 根页面是分组列表：分组标题 + 入口行
    expect(find.text('线路与代理'), findsOneWidget);
    expect(find.text('VLESS 链接'), findsOneWidget);
    // 只显示条目数，不给可编辑的 proxyip 文本框；内容也不展示
    expect(find.textContaining('proxyip'), findsOneWidget);
    expect(find.text('每行 ip:port，用于替换 ws 路径里的回源地址'), findsNothing);
    // 抓取代理已删除：抓取走什么代理由这里的 VLESS 线路决定
    expect(find.text('抓取代理'), findsNothing);

    // 具体配置收进弹层：点「VLESS 链接」才看到输入框与「加载文件」
    await tester.tap(find.text('VLESS 链接'));
    await tester.pumpAndSettle();
    expect(find.text('加载文件'), findsOneWidget);
    expect(find.text('VLESS 链接'), findsWidgets);

    expect(tester.takeException(), isNull);
  });
}
