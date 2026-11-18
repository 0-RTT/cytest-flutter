import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/pages/settings_page.dart';

/// GitHub 设置只保留「仓库地址」+ Token。
///
/// 旧版还有一个 `githubPath`（仓库内文件路径）输入框，现在路径由推送页
/// 按格式（base64/yaml）各自决定，设置页不再需要它。这里同时钉住：
/// 1) 有「仓库地址」输入框；
/// 2) 没有「文件路径」；
/// 3) 非法仓库地址保存时给出可读提示，且不落库。
Widget _host(AppState state) => ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: SettingsPage()),
    );

Finder _fieldByLabel(String label) => find.widgetWithText(TextField, label);

/// 设置页是一个懒构建的 ListView，默认 800×600 视口只建出前两个分区，
/// 「GitHub 推送」根本不会被 build。给一个足够高的视口让所有分区都实体化。
void _tallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SettingsPage · GitHub 设置', () {
    testWidgets('只有仓库地址和 Token，没有「文件路径」', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(_host(AppState()));
      await tester.pumpAndSettle();

      expect(find.text('GitHub 推送'), findsOneWidget);
      expect(_fieldByLabel('仓库地址'), findsOneWidget);
      expect(_fieldByLabel('Token'), findsOneWidget);

      // 旧字段必须彻底消失
      expect(find.textContaining('文件路径'), findsNothing);
      expect(find.textContaining('仓库内路径'), findsNothing);

      // 远程执行的「私钥路径」是另一回事，不能因此被删
      expect(_fieldByLabel('私钥路径'), findsOneWidget);
    });

    testWidgets('仓库地址的 hint 给出可照抄的示例', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(_host(AppState()));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(_fieldByLabel('仓库地址'));
      expect(
        field.decoration?.hintText,
        'https://github.com/0-RTT/sub',
      );
    });

    testWidgets('非法仓库地址（只有 owner）保存时给出可读提示且不落库', (tester) async {
      _tallViewport(tester);
      final state = AppState();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await tester.enterText(_fieldByLabel('仓库地址'), 'https://github.com/0-RTT');
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pump();

      expect(
        find.textContaining('仓库地址格式不对'),
        findsOneWidget,
        reason: '非法地址必须提示用户怎么改，而不是静默失败',
      );
      // 提示语要带上正确写法
      expect(find.textContaining('https://github.com/owner/repo'), findsOneWidget);
      // 校验失败就必须放弃本次保存
      expect(state.settings.githubRepo, isEmpty);
    });

    testWidgets('合法仓库地址被规范化成 owner/repo 后落库并回填', (tester) async {
      _tallViewport(tester);
      final state = AppState();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await tester.enterText(
        _fieldByLabel('仓库地址'),
        'https://github.com/0-RTT/sub.git',
      );
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(state.settings.githubRepo, '0-RTT/sub');
      expect(find.textContaining('仓库地址格式不对'), findsNothing);
      // 回填：用户能看到实际生效的值
      final field = tester.widget<TextField>(_fieldByLabel('仓库地址'));
      expect(field.controller?.text, '0-RTT/sub');
    });

    testWidgets('仓库地址留空可直接保存（不强制配置 GitHub）', (tester) async {
      _tallViewport(tester);
      final state = AppState();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(find.textContaining('仓库地址格式不对'), findsNothing);
      expect(state.settings.githubRepo, isEmpty);
    });
  });

  // 真实事故：用户看到「延迟 800ms」以为节点废了，就去设置里填 200ms，
  // 结果一键测试把所有能用的候选都筛掉，看起来像「全部失败」。
  // 所以这一项必须自解释：0 = 不限，且只影响测速前的筛选。
  group('SettingsPage · 延迟上限', () {
    testWidgets('hint 写明 0 = 不限（推荐）', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(_host(AppState()));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(_fieldByLabel('延迟上限（ms）'));
      expect(field.decoration?.hintText, '0 = 不限（推荐）');
    });

    testWidgets('helper 点明只用于省测速时间、不代表节点不可用', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(_host(AppState()));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(_fieldByLabel('延迟上限（ms）'));
      final helper = field.decoration?.helperText ?? '';
      expect(helper, contains('不代表节点不可用'));
      expect(helper, contains('延迟测试'),
          reason: '要说明「延迟测试」不受此项影响，否则用户不敢调');
    });

    testWidgets('默认值读出来就是 0（不限）', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(_host(AppState()));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(_fieldByLabel('延迟上限（ms）'));
      expect(field.controller?.text, '0');
    });
  });
}
