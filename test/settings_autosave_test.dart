import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cytest/core/settings.dart';
import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/pages/settings_page.dart';

/// 设置页「配置了却丢了」的三条根因，逐条钉死：
///
/// 1. **绑定时序**：`main.dart` 是 `AppState()..boot()`，boot 是异步的、UI 不等它。
///    页面在 boot 完成前把表单绑成默认值，之后 `settings` 被换成磁盘里的真实配置，
///    但页面不会重新绑定 → 点一次「保存」就把 15 个字段写回默认值。
/// 2. **全量写回**：旧 `_save()` 把 16 个 controller 全写进 `settings`，
///    只要有一个字段的值是「过期的默认值」，磁盘上的用户配置就被抹掉。
/// 3. **没有自动保存**：改完直接切走就丢，只有底部那个按钮。
///
/// 这里的断言全部是「用户能看见的后果」，不是内部实现：
/// 内存里的 `settings`、以及真正落盘的那份 JSON。
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

Future<void> _closeSheet(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '完成'));
  await tester.pumpAndSettle();
}

Future<void> _tapSave(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '保存'));
  await tester.pumpAndSettle();
}

void _tallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 一份「磁盘上已经存好的」非默认配置 —— 每一项都和 `Defaults` 不同，
/// 这样「被默认值覆盖」在断言里一定看得出来。
AppSettings _storedSettings() => AppSettings()
  ..speedUrl = 'https://example.com/500.zip'
  ..latencyUrl = 'https://example.com/204'
  ..githubRepo = 'acme/sub'
  ..githubToken = 'gh-token'
  ..remoteHost = '10.0.0.9'
  ..remotePort = 2202
  ..remoteUser = 'ubuntu'
  ..remotePassword = 'pw'
  ..remoteKeyPath = '/home/ubuntu/.ssh/id_ed25519'
  ..sha1Concurrency = 45
  ..latencyConcurrency = 77
  ..speedConcurrency = 6
  ..maxLatency = 900
  ..dialTimeout = 7
  ..downloadTimeout = 21
  ..vlessLinks = <String>[
    'vless://uuid@a.example:443?type=xhttp',
    'vless://uuid@b.example:443?type=xhttp',
  ];

/// 「setString 返回成功但没真正持久化」的插件级故障。
class _SilentDropState extends AppState {
  @override
  Future<void> saveSettings() async {
    // 故意什么都不写：内存里的 settings 已经改了，磁盘还是旧的。
  }
}

/// 第一次写盘抛异常，之后正常 —— 用来验「失败后能不能重试成功」。
class _FailOnceState extends AppState {
  int attempts = 0;

  @override
  Future<void> saveSettings() async {
    attempts++;
    if (attempts == 1) throw StateError('第一次写入被系统拒绝');
    await super.saveSettings();
  }
}

/// 第一次「写成功」但没落盘，之后正常 —— 用来验「自检失败后能不能重试成功」。
class _DropOnceState extends AppState {
  int attempts = 0;

  @override
  Future<void> saveSettings() async {
    attempts++;
    if (attempts == 1) return; // 返回成功，但磁盘上什么都没写
    await super.saveSettings();
  }
}

/// 落盘直接抛异常（磁盘满 / 权限不足）。
class _FailingState extends AppState {
  @override
  Future<void> saveSettings() async {
    throw StateError('写入被系统拒绝');
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('设置页 · boot 与表单的绑定时序', () {
    testWidgets('boot 完成后只改一个字段保存：其余字段保持磁盘上的值', (tester) async {
      _tallViewport(tester);
      // 真实时序：AppState 先构造（booting = true，settings = 默认值），
      // 页面随即挂载（在 IndexedStack 里常驻），boot 才在后面完成。
      final state = AppState();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      // boot 完成：磁盘上的真实配置替换进来。
      final loaded = _storedSettings();
      state.settings = loaded;
      state.booting = false;
      state.notifyListeners();
      await tester.pumpAndSettle();

      // 用户只改一个字段。
      await _openGroup(tester, '超时');
      await tester.enterText(_fieldByLabel('连接超时（秒）'), '9');
      await _closeSheet(tester);
      await _tapSave(tester);

      expect(state.settings.dialTimeout, 9, reason: '改的那个字段要生效');
      expect(state.settings.speedUrl, 'https://example.com/500.zip',
          reason: '没编辑过的字段必须保留磁盘上的值，不能被表单里的默认值覆盖');
      expect(state.settings.latencyUrl, 'https://example.com/204');
      expect(state.settings.githubRepo, 'acme/sub');
      expect(state.settings.githubToken, 'gh-token');
      expect(state.settings.remoteHost, '10.0.0.9');
      expect(state.settings.remotePort, 2202);
      expect(state.settings.sha1Concurrency, 45);
      expect(state.settings.latencyConcurrency, 77);
      expect(state.settings.speedConcurrency, 6);
      expect(state.settings.maxLatency, 900);
      expect(state.settings.downloadTimeout, 21);
      expect(state.settings.vlessLinks.length, 2);

      final disk = await tester.runAsync(() => AppSettings.load());
      expect(disk!.speedUrl, 'https://example.com/500.zip',
          reason: '落盘的必须是合并后的结果，否则重启后用户看到的就是「配置丢了」');
      expect(disk.sha1Concurrency, 45);
      expect(disk.dialTimeout, 9);
    });

    testWidgets('boot 完成后表单显示磁盘上的值（未编辑字段被同步）', (tester) async {
      _tallViewport(tester);
      final state = AppState();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      state.settings = _storedSettings();
      state.booting = false;
      state.notifyListeners();
      await tester.pumpAndSettle();

      await _openGroup(tester, '速度测试地址');
      final speedField = tester.widget<TextField>(_fieldByLabel('速度测试地址'));
      expect(speedField.controller?.text, 'https://example.com/500.zip',
          reason: '读到设置后表单得跟着变，否则用户看到的是「上次启动的默认值」');
      await _closeSheet(tester);

      await _openGroup(tester, '并发');
      expect(
        tester.widget<TextField>(_fieldByLabel('指纹筛选并发')).controller?.text,
        '45',
      );
    });

    testWidgets('没同步成功也不会把其它字段写成默认值（纵深防御）', (tester) async {
      _tallViewport(tester);
      final state = AppState();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      // 最坏情况：settings 被换掉了，但页面**没有**收到通知（boot 卡住/异常）。
      state.settings = _storedSettings();
      await tester.pump();

      await _openGroup(tester, '并发');
      await tester.enterText(_fieldByLabel('指纹筛选并发'), '33');
      await _closeSheet(tester);
      await _tapSave(tester);

      expect(state.settings.sha1Concurrency, 33);
      expect(state.settings.speedUrl, 'https://example.com/500.zip',
          reason: '只写脏字段：表单里那个「过期的默认值」不许写回 settings');
      expect(state.settings.githubRepo, 'acme/sub');
      expect(state.settings.remotePort, 2202);
    });
  });

  group('设置页 · 自动保存', () {
    testWidgets('停止输入 600ms 后自动落盘，不需要点「保存」', (tester) async {
      _tallViewport(tester);
      final state = AppState()..booting = false;
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, '并发');
      await tester.enterText(_fieldByLabel('指纹筛选并发'), '33');
      await _closeSheet(tester);

      // 什么都不点，只等 debounce。
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();

      expect(state.settings.sha1Concurrency, 33);
      final disk = await tester.runAsync(() => AppSettings.load());
      expect(disk!.sha1Concurrency, 33,
          reason: '「配置了不会自动保存」——改完直接切走也必须落盘');
    });

    testWidgets('连续改两个字段：两次自动保存串行，谁都不丢', (tester) async {
      _tallViewport(tester);
      final state = AppState()..booting = false;
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, '并发');
      await tester.enterText(_fieldByLabel('指纹筛选并发'), '33');
      await _closeSheet(tester);
      await _openGroup(tester, '超时');
      await tester.enterText(_fieldByLabel('下载超时（秒）'), '22');
      await _closeSheet(tester);

      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();

      final disk = await tester.runAsync(() => AppSettings.load());
      expect(disk!.sha1Concurrency, 33);
      expect(disk.downloadTimeout, 22);
      expect(disk.latencyUrl, Defaults.latencyUrl,
          reason: '没碰过的字段不能被顺手改掉');
    });
  });

  group('设置页 · 失败必须可见', () {
    testWidgets('落盘抛异常时提示用户并写日志（不能静默）', (tester) async {
      _tallViewport(tester);
      final state = _FailingState()..booting = false;
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, '并发');
      await tester.enterText(_fieldByLabel('指纹筛选并发'), '33');
      await _closeSheet(tester);
      await _tapSave(tester);

      expect(find.textContaining('保存失败'), findsWidgets,
          reason: '用户必须知道这次没存上');
      expect(
        state.logs.any((l) => l.contains('保存失败')),
        isTrue,
        reason: '日志里也要留痕，否则真机上报「保存没反应」时无从查起',
      );
    });

    testWidgets('保存后自检：磁盘和内存对不上要明确报错', (tester) async {
      _tallViewport(tester);
      final state = _SilentDropState()..booting = false;
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, '并发');
      await tester.enterText(_fieldByLabel('指纹筛选并发'), '33');
      await _closeSheet(tester);
      await _tapSave(tester);

      expect(find.textContaining('对不上'), findsWidgets,
          reason: '写成功但没真正持久化，必须当场报出来，而不是留到下次启动才发现');
      expect(state.logs.any((l) => l.contains('对不上')), isTrue);
    });
  });

  group('设置页 · 保存失败后的重试与自检覆盖（R1 / R4）', () {
    testWidgets('R1：失败要回滚内存，再点「保存」要真的重试并落盘', (tester) async {
      _tallViewport(tester);
      final state = _FailOnceState()..booting = false;
      state.settings = _storedSettings();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, '并发');
      await tester.enterText(_fieldByLabel('指纹筛选并发'), '33');
      await _closeSheet(tester); // 关弹层 = 一次 flush，第一次写盘被拒
      await tester.pumpAndSettle();

      expect(state.attempts, 1);
      expect(state.logs.any((l) => l.contains('保存失败')), isTrue);
      expect(state.settings.sha1Concurrency, 45,
          reason: '失败必须回滚乐观写入：界面不能显示「存上了」而磁盘还是旧值');

      // 用户看到失败，再点一次「保存」。
      await _tapSave(tester);
      expect(state.attempts, greaterThan(1),
          reason: '快照不能在落盘前推进，否则第二次点击一次写盘都不发');
      expect(state.settings.sha1Concurrency, 33);
      final disk = await tester.runAsync(() => AppSettings.load());
      expect(disk!.sha1Concurrency, 33, reason: '重试成功后磁盘必须是新值');
      expect(disk.speedUrl, 'https://example.com/500.zip',
          reason: '重试只该动脏字段，别把其它字段写丢');
    });

    testWidgets('R1：读回自检对不上也走同一条失败路径，重试有效', (tester) async {
      _tallViewport(tester);
      final state = _DropOnceState()..booting = false;
      state.settings = _storedSettings();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, '并发');
      await tester.enterText(_fieldByLabel('指纹筛选并发'), '33');
      await _closeSheet(tester); // 第一次「写成功」但没落盘 → 自检报对不上
      await tester.pumpAndSettle();

      expect(state.attempts, 1);
      expect(find.textContaining('对不上'), findsWidgets);
      expect(state.logs.any((l) => l.contains('对不上')), isTrue);
      expect(state.settings.sha1Concurrency, 45, reason: '自检不过同样要回滚');

      await _tapSave(tester);
      expect(state.attempts, greaterThan(1));
      final disk = await tester.runAsync(() => AppSettings.load());
      expect(disk!.sha1Concurrency, 33, reason: '自检失败不能被当成成功，重试要能存住');
    });

    testWidgets('R4：只改 Token 这类字段时的静默丢写也能被自检抓到', (tester) async {
      _tallViewport(tester);
      // 内存与磁盘除 Token 外完全一致（都是默认值），于是「只有 Token 对不上」，
      // 旧实现只比 8 个字段时这一条会**静默通过**。
      final state = _SilentDropState()..booting = false;
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, 'GitHub 推送');
      await tester.enterText(_fieldByLabel('Token'), 'gh-token-2');
      await _closeSheet(tester);
      await _tapSave(tester);

      expect(find.textContaining('GitHub Token'), findsWidgets,
          reason: '16 个字段全比：Token / 远程密码 / 端口 / 私钥 / 链接 / 超时都不能漏');
      expect(state.logs.any((l) => l.contains('GitHub Token')), isTrue);
      expect(state.settings.githubToken, isEmpty, reason: '失败后内存要回滚到磁盘值');
    });
  });
}
