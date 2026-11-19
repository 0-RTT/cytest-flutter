import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:cytest/app.dart';
import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/home.dart';
import 'package:cytest/ui/widgets/glass.dart';

/// 动效与材质的硬契约。
///
/// 这两条都是「回归防线」：以后谁想加回毛玻璃 / 换回转场，
/// 测试会先拦住，而不是等真机上再发现卡顿。
void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: AppState(),
        child: const CytestApp(),
      ),
    );
    await tester.pump();
  }

  testWidgets('全 App 不使用 BackdropFilter（毛玻璃是转场卡顿的根源）',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpApp(tester);

    // 首页静止时就没有模糊层
    expect(find.byType(BackdropFilter), findsNothing,
        reason: '首页不应有 BackdropFilter');

    // 进子页面：转场中与转场后都不能冒出模糊层
    await tester.tap(find.text('获取数据'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(BackdropFilter), findsNothing,
        reason: '转场过程中不应有 BackdropFilter');

    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing,
        reason: '子页面稳定后也不应有 BackdropFilter');
  });

  testWidgets('转场使用 260ms 轻量淡入，而不是默认 Zoom', (tester) async {
    await pumpApp(tester);

    final context = tester.element(find.byType(HomeShell));
    final builders = Theme.of(context).pageTransitionsTheme.builders;
    final android = builders[TargetPlatform.android];

    expect(android, isA<GlassPageTransitionsBuilder>(),
        reason: 'Android 必须走自定义轻量转场（默认 Zoom 会整页缩放 + 阴影）');
    expect(android!.transitionDuration, const Duration(milliseconds: 260),
        reason: '转场时长应为 260ms');
  });

  testWidgets('子页面自带同款渐变底（避免转场透出上一页造成重影）',
      (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('获取数据'));
    await tester.pumpAndSettle();

    // GlassRoute 会给每个页面铺一层 GlassBackground：
    // 首页 1 层 + 当前子页 1 层（旧页在转场结束后不再绘制，但仍在树上）。
    expect(find.byType(GlassBackground), findsWidgets);
    expect(find.text('获取数据'), findsWidgets);
  });
}
