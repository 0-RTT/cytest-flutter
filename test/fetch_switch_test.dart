import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/pages/fetch_page.dart';

Widget _host(Widget child) => ChangeNotifierProvider<AppState>.value(
      value: AppState(),
      child: MaterialApp(home: child),
    );

void main() {
  testWidgets('抓取页默认走代理，可切到直连', (tester) async {
    await tester.pumpWidget(_host(const FetchPage()));
    await tester.pump();

    expect(find.text('访问方式'), findsOneWidget);
    final segmented = find.byType(SegmentedButton<bool>);
    expect(segmented, findsOneWidget);
    expect(
      tester.widget<SegmentedButton<bool>>(segmented).selected,
      {true},
      reason: '默认走代理，与 Kotlin useProxy=true 一致',
    );

    await tester.tap(find.text('直连'));
    await tester.pump();
    expect(tester.widget<SegmentedButton<bool>>(segmented).selected, {false});
  });
}
