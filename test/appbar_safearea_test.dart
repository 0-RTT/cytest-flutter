import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/pages/fetch_page.dart';

/// 状态栏与标题栏的边界。
///
/// 回归过一次：GlassAppBar 外面套了一层定高 56 的 Container，Scaffold 仍按
/// `56 + 状态栏高度` 预留空间，于是标题被往下推、底线跑到了状态栏下面，
/// 看起来像「状态栏和标题栏粘在一起」。这里直接断言几何关系。
void main() {
  testWidgets('带状态栏时：AppBar 总高 = 56 + 状态栏，标题不压状态栏', (tester) async {
    tester.view.physicalSize = const Size(1080, 2160);
    tester.view.devicePixelRatio = 3.0;
    // 24dp 状态栏
    tester.view.padding = const FakeViewPadding(top: 72);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: AppState(),
      child: const MaterialApp(home: FetchPage()),
    ));
    await tester.pumpAndSettle();

    final appBar = tester.getRect(find.byType(AppBar));
    expect(appBar.height, greaterThanOrEqualTo(kToolbarHeight + 24 - 0.5),
        reason: 'AppBar 必须包含状态栏高度，否则内容会被裁掉');
    expect(appBar.top, 0, reason: 'AppBar 从屏幕顶部开始画，状态栏区域由它自己填充');

    final title = tester.getRect(find.text('获取数据'));
    expect(title.top, greaterThanOrEqualTo(24),
        reason: '标题不能压在状态栏区域内');

    // 关键：正文必须整块落在标题栏下方。旧写法里 Scaffold 只按 56 预留，
    // 而 AppBar 实际有 80 高 —— 正文会被顶上去 24px，压在标题栏底下，
    // 这就是「状态栏和标题栏混在一起」的真身。
    final firstBody = tester.getRect(find.text('Censys 查询'));
    expect(firstBody.top, greaterThanOrEqualTo(appBar.bottom),
        reason: '正文顶边必须 >= 标题栏底边（否则就是被标题栏盖住了）');

    expect(tester.takeException(), isNull);
  });

  testWidgets('没有状态栏时（平板/测试环境）：AppBar 仍是 56 高', (tester) async {
    tester.view.physicalSize = const Size(1080, 2160);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: AppState(),
      child: const MaterialApp(home: FetchPage()),
    ));
    await tester.pumpAndSettle();

    final appBar = tester.getRect(find.byType(AppBar));
    expect(appBar.height, moreOrLessEquals(kToolbarHeight, epsilon: 0.5));
    expect(tester.takeException(), isNull);
  });

  test('源码守卫：GlassAppBar 不许再被定高 Container 包裹', () {
    // 几何断言抓不住这个问题（AppBar 自己仍有 80 高），但「外面多了个容器」
    // 是这次 bug 的根因：Scaffold 按 preferredSize=56 预留，容器却被裁成 56，
    // 于是我们画的那条底线跑到状态栏下面，看起来就和状态栏糊在一起。
    final src = File('lib/ui/widgets/glass.dart').readAsStringSync();
    final start = src.indexOf('class GlassAppBar');
    final end = src.indexOf('class GlassBar');
    expect(start, greaterThan(0));
    expect(end, greaterThan(start));
    final block = src.substring(start, end);
    expect(block.contains('return Container('), isFalse,
        reason: 'GlassAppBar 必须直接把 AppBar 交给 Scaffold，外层不能再包容器');
    expect(block.contains('shape: Border(bottom: Glass.hairline(theme))'), isTrue,
        reason: '底线要用 AppBar 的 shape 画，它参与 AppBar 自身布局');
  });
}
