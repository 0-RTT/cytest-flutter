import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cytest/core/settings.dart' show Defaults;
import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/pages/settings_page.dart';

Widget _host(AppState state) => ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: SettingsPage()),
    );

Finder _fieldByLabel(String label) => find.widgetWithText(TextField, label);

/// 设置页是「分组列表 + 弹层编辑」：字段都在弹层里，必须先点那一行。
Future<void> _openGroup(WidgetTester tester, String rowTitle) async {
  await tester.tap(find.text(rowTitle).first);
  await tester.pumpAndSettle();
}

/// 关掉弹层（「完成」），回到根页面。保存按钮在根页面的底部操作条上。
Future<void> _closeSheet(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '完成'));
  await tester.pumpAndSettle();
}

void _tallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SettingsPage · 分组列表形态', () {
    testWidgets('根页面只有分组行，字段收在弹层里', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(_host(AppState()));
      await tester.pumpAndSettle();

      for (final t in [
        'VLESS 链接',
        'proxyip',
        '并发',
        '超时',
        '延迟测试地址',
        '速度测试地址',
        'GitHub 推送',
        '远程执行',
      ]) {
        expect(find.text(t), findsOneWidget, reason: '缺少入口行：$t');
      }
      // 字段默认不可见（省得长表单把页面拉得很长）
      expect(_fieldByLabel('仓库地址'), findsNothing);
      expect(_fieldByLabel('延迟上限（ms）'), findsNothing);
      // 分组小标题
      expect(find.text('线路与代理'), findsOneWidget);

      await _openGroup(tester, 'GitHub 推送');
      expect(_fieldByLabel('仓库地址'), findsOneWidget);
      expect(_fieldByLabel('Token'), findsOneWidget);
      await _closeSheet(tester);
      expect(_fieldByLabel('仓库地址'), findsNothing);
    });
  });

  group('SettingsPage · GitHub 设置', () {
    testWidgets('只有仓库地址和 Token，没有「文件路径」', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(_host(AppState()));
      await tester.pumpAndSettle();
      await _openGroup(tester, 'GitHub 推送');

      expect(find.text('GitHub 推送'), findsWidgets);
      expect(_fieldByLabel('仓库地址'), findsOneWidget);
      expect(_fieldByLabel('Token'), findsOneWidget);

      // 旧字段必须彻底消失
      expect(find.textContaining('文件路径'), findsNothing);
      expect(find.textContaining('仓库内路径'), findsNothing);

      // 远程执行的「私钥路径」是另一回事，不能因此被删
      await _closeSheet(tester);
      await _openGroup(tester, '远程执行');
      expect(_fieldByLabel('私钥路径'), findsOneWidget);
    });

    testWidgets('仓库地址的 hint 给出可照抄的示例', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(_host(AppState()));
      await tester.pumpAndSettle();
      await _openGroup(tester, 'GitHub 推送');

      final field = tester.widget<TextField>(_fieldByLabel('仓库地址'));
      expect(field.decoration?.hintText, 'https://github.com/0-RTT/sub');
    });

    testWidgets('非法仓库地址（只有 owner）保存时给出可读提示且不落库', (tester) async {
      _tallViewport(tester);
      final state = AppState();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, 'GitHub 推送');
      await tester.enterText(_fieldByLabel('仓库地址'), 'https://github.com/0-RTT');
      await _closeSheet(tester);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pump();

      expect(
        find.textContaining('仓库地址格式不对'),
        findsOneWidget,
        reason: '非法地址必须提示用户怎么改，而不是静默失败',
      );
      expect(
          find.textContaining('https://github.com/owner/repo'), findsOneWidget);
      expect(state.settings.githubRepo, isEmpty);
    });

    testWidgets('合法仓库地址被规范化成 owner/repo 后落库并回填', (tester) async {
      _tallViewport(tester);
      final state = AppState();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, 'GitHub 推送');
      await tester.enterText(
        _fieldByLabel('仓库地址'),
        'https://github.com/0-RTT/sub.git',
      );
      await _closeSheet(tester);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(state.settings.githubRepo, '0-RTT/sub');
      expect(find.textContaining('仓库地址格式不对'), findsNothing);
      // 回填：用户能看到实际生效的值
      await _openGroup(tester, 'GitHub 推送');
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

  // 延迟与速度是两条口径（延迟 = 204 小端点、速度 = 大文件），入口必须分开；
  // 合在一起正是「延迟读数远大于 v2rayN」的老 bug。
  group('SettingsPage · 延迟 / 速度测试地址分离', () {
    testWidgets('两个入口各自独立，弹层字段对得上', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(_host(AppState()));
      await tester.pumpAndSettle();

      await _openGroup(tester, '延迟测试地址');
      final latency = tester.widget<TextField>(_fieldByLabel('延迟测试地址'));
      expect(latency.decoration?.hintText, Defaults.latencyUrl);
      await _closeSheet(tester);

      await _openGroup(tester, '速度测试地址');
      final speed = tester.widget<TextField>(_fieldByLabel('速度测试地址'));
      expect(speed.decoration?.hintText, Defaults.speedUrl);
      // 旧的「测速地址」入口必须彻底消失，避免用户以为只配一个就够
      expect(find.text('测速地址'), findsNothing);
    });

    testWidgets('延迟地址的说明写明「不可达时自动尝试内置候选」', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(_host(AppState()));
      await tester.pumpAndSettle();
      await _openGroup(tester, '延迟测试地址');

      expect(
        find.textContaining('自动尝试内置候选'),
        findsOneWidget,
        reason: '端点会静默切换，用户必须知道这件事，否则看不懂阶段文案里的「端点 2/3」',
      );
    });

    testWidgets('速度地址清空后保存 → 也回落默认（两条地址必须对称）', (tester) async {
      _tallViewport(tester);
      final state = AppState();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, '速度测试地址');
      await tester.enterText(_fieldByLabel('速度测试地址'), '');
      await _closeSheet(tester);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(
        state.settings.speedUrl,
        Defaults.speedUrl,
        reason: '空的速度地址会一路传到 pipeline 的 speedTestURL，'
            '让三阶段下载直接报配置错误；必须和延迟地址一样有兜底',
      );
      expect(state.settings.latencyUrl, Defaults.latencyUrl);
    });

    testWidgets('延迟地址清空后保存 → 回落默认值（不能落盘成空串）', (tester) async {
      _tallViewport(tester);
      final state = AppState();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, '延迟测试地址');
      await tester.enterText(_fieldByLabel('延迟测试地址'), '');
      await _closeSheet(tester);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();

      expect(
        state.settings.latencyUrl,
        Defaults.latencyUrl,
        reason: '空地址会让每条线路报「地址非法」，清空输入框的语义是恢复默认',
      );
      // 速度地址不能被这次保存顺手改掉
      expect(state.settings.speedUrl, Defaults.speedUrl);
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
      await _openGroup(tester, '并发');

      final field = tester.widget<TextField>(_fieldByLabel('延迟上限（ms）'));
      expect(field.decoration?.hintText, '0 = 不限（推荐）');
    });

    testWidgets('helper 点明只用于省测速时间、不代表节点不可用', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(_host(AppState()));
      await tester.pumpAndSettle();
      await _openGroup(tester, '并发');

      final field = tester.widget<TextField>(_fieldByLabel('延迟上限（ms）'));
      final helper = field.decoration?.helperText ?? '';
      expect(helper, contains('不代表节点不可用'));
      expect(helper, contains('延迟测试'), reason: '要说明「延迟测试」不受此项影响，否则用户不敢调');
    });

    testWidgets('默认值读出来就是 0（不限）', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(_host(AppState()));
      await tester.pumpAndSettle();
      await _openGroup(tester, '并发');

      final field = tester.widget<TextField>(_fieldByLabel('延迟上限（ms）'));
      expect(field.controller?.text, '0');
    });
  });

  // 「抓取代理」是「线路与代理」的第二份开关：同一件事两个值必然漂移，
  // 而且它只被设置页读写、没有任何代码真正使用（grep fetchProxy 零调用）。
  group('SettingsPage · 已移除的开关', () {
    testWidgets('不再提供「抓取代理」输入项', (tester) async {
      _tallViewport(tester);
      await tester.pumpWidget(_host(AppState()));
      await tester.pumpAndSettle();

      expect(find.text('抓取代理'), findsNothing);
      await _openGroup(tester, '线路与代理');
      expect(find.widgetWithText(TextField, '抓取代理'), findsNothing);
    });
  });
}
