import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/pages/history_page.dart';

/// 「记录」页的终态契约。
///
/// 测试环境里没有 path_provider 插件，`Paths.root()` 必然抛
/// MissingPluginException —— 正好是线上「读盘失败」的等价物。
///
/// 旧实现没有 try/catch：异常后 `_loading` 永远是 true，页面永久转圈。
/// 这两条断言就是拦它的：**任何一次读盘失败都必须落到可读的错误态**。
void main() {
  Widget host() => ChangeNotifierProvider<AppState>.value(
        value: AppState(),
        child: const MaterialApp(home: HistoryPage()),
      );

  testWidgets('读盘失败时给出错误说明与重试，而不是永远转圈', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump(); // 首帧：进入加载中

    // 失败应当很快落地；pumpAndSettle 若因转圈动画超时会直接失败。
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '读盘失败后不能再有转圈指示器');
    expect(find.text('记录没有加载出来'), findsOneWidget);
    // 具体分支可能是「读取记录失败：…」或「读取记录超时…」，
    // 这里只钉住「必须把原因写给用户看」这个契约。
    expect(find.textContaining('读取记录'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);
  });

  testWidgets('点「重试」不会卡死，仍停在错误态并可再次重试', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '重试'));
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('记录没有加载出来'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
