// 独立回归验证：设置页「配置了不会自动保存 / 手动保存也会丢」。
//
// 与 `settings_autosave_test.dart` 刻意分开写，目的不同：
// - 那份是修复者的自证；这份专门去**证伪**，逐条压「只写脏字段」这条护栏、
//   16 个字段的覆盖完整性、去抖/串行的时序、以及 dispose / 失败可见等边界。
// - 断言一律落在「用户能看见的后果」上：内存里的 `AppSettings`、真正落盘的
//   JSON、界面上的文案。不碰任何私有成员，避免测试与实现耦合。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cytest/core/settings.dart';
import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/pages/settings_page.dart';

// ---------------------------------------------------------------- 测试脚手架

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

Future<AppSettings> _readDisk(WidgetTester tester) async {
  final disk = await tester.runAsync(() => AppSettings.load());
  return disk!;
}

/// 一份「磁盘上已经存好的」配置：每一项都与 [Defaults] 不同，
/// 于是「被默认值覆盖」这件事在断言里一定看得见。
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

/// 数「落盘了几次」。`saveSettings` 是本页唯一的写盘出口，
/// 去抖 / 串行 / 回环三类问题最终都表现为这个计数不对。
class _CountingState extends AppState {
  int saves = 0;

  @override
  Future<void> saveSettings() async {
    saves++;
    await super.saveSettings();
  }
}

/// 落盘被闸门卡住：用来制造「保存 A 还没写完，用户又改了 B」的并发窗口。
class _GatedState extends AppState {
  final List<String> order = <String>[];
  final List<Map<String, dynamic>> snapshots = <Map<String, dynamic>>[];

  final Completer<void> _completer = Completer<void>();
  bool _blocked = true;

  /// 放行（此后所有保存都不再被卡住）。
  void openGate() {
    _blocked = false;
    if (!_completer.isCompleted) _completer.complete();
  }

  @override
  Future<void> saveSettings() async {
    order.add('start');
    // 这个快照 = 本次保存即将写下的内容。
    snapshots.add(Map<String, dynamic>.from(settings.toJson()));
    if (_blocked) await _completer.future;
    await super.saveSettings();
    order.add('end');
  }
}

/// `setString` 返回成功但没真正持久化（插件级故障），用来验落盘自检。
class _SilentDropState extends AppState {
  @override
  Future<void> saveSettings() async {
    // 故意什么都不写。
  }
}

/// 落盘直接抛异常（磁盘满 / 权限不足）。
class _FailingState extends AppState {
  @override
  Future<void> saveSettings() async {
    throw StateError('写入被系统拒绝');
  }
}

/// 第一次落盘失败、之后恢复正常（模拟「磁盘临时 busy / 权限瞬时不足」）。
class _FailOnceState extends AppState {
  int attempts = 0;

  @override
  Future<void> saveSettings() async {
    attempts++;
    if (attempts == 1) throw StateError('第一次写入被系统拒绝');
    await super.saveSettings();
  }
}

/// 落盘「成功」但**只丢一个字段**（远程端口）。
///
/// 用来验自检是否真的逐字段比：只比 8 个关键字段的实现会漏掉 remotePort。
class _DropsRemotePortState extends AppState {
  @override
  Future<void> saveSettings() async {
    final keep = settings.remotePort;
    settings.remotePort = 22; // 假装这个字段没写进去
    try {
      await super.saveSettings();
    } finally {
      settings.remotePort = keep; // 内存保持用户的值
    }
  }
}

/// 16 个可编辑字段的读值器：`_read` 从任意一份 settings 里取出该字段的
/// 「可比较值」（列表类型统一拍平成字符串，避免 List 身份比较的坑）。
class _FieldCase {
  const _FieldCase({
    required this.name,
    required this.row,
    required this.label,
    required this.newText,
    required this.expectedNew,
    required this.read,
  });

  final String name;

  /// 在根页面上点哪一行才能进到该字段所在的弹层
  /// （注意「线路与代理」只是分组小标题，可点的是「VLESS 链接」那一行）。
  final String row;
  final String label;
  final String newText;
  final Object expectedNew;
  final Object Function(AppSettings s) read;
}

const List<_FieldCase> _allFields = <_FieldCase>[
  _FieldCase(
    name: '指纹筛选并发',
    row: '并发',
    label: '指纹筛选并发',
    newText: '33',
    expectedNew: 33,
    read: _readSha1,
  ),
  _FieldCase(
    name: '延迟测试并发',
    row: '并发',
    label: '延迟测试并发',
    newText: '66',
    expectedNew: 66,
    read: _readLatencyConcurrency,
  ),
  _FieldCase(
    name: '速度测试并发',
    row: '并发',
    label: '速度测试并发',
    newText: '5',
    expectedNew: 5,
    read: _readSpeedConcurrency,
  ),
  _FieldCase(
    name: '延迟上限',
    row: '并发',
    label: '延迟上限（ms）',
    newText: '450',
    expectedNew: 450,
    read: _readMaxLatency,
  ),
  _FieldCase(
    name: '连接超时',
    row: '超时',
    label: '连接超时（秒）',
    newText: '9',
    expectedNew: 9,
    read: _readDialTimeout,
  ),
  _FieldCase(
    name: '下载超时',
    row: '超时',
    label: '下载超时（秒）',
    newText: '22',
    expectedNew: 22,
    read: _readDownloadTimeout,
  ),
  _FieldCase(
    name: '速度测试地址',
    row: '速度测试地址',
    label: '速度测试地址',
    newText: 'https://example.com/800.zip',
    expectedNew: 'https://example.com/800.zip',
    read: _readSpeedUrl,
  ),
  _FieldCase(
    name: '延迟测试地址',
    row: '延迟测试地址',
    label: '延迟测试地址',
    newText: 'https://example.com/204-b',
    expectedNew: 'https://example.com/204-b',
    read: _readLatencyUrl,
  ),
  _FieldCase(
    name: '仓库地址',
    row: 'GitHub 推送',
    label: '仓库地址',
    newText: 'beta/proj',
    expectedNew: 'beta/proj',
    read: _readGithubRepo,
  ),
  _FieldCase(
    name: 'Token',
    row: 'GitHub 推送',
    label: 'Token',
    newText: 'gh-token-2',
    expectedNew: 'gh-token-2',
    read: _readGithubToken,
  ),
  _FieldCase(
    name: '远程主机',
    row: '远程执行',
    label: '主机',
    newText: '10.0.0.10',
    expectedNew: '10.0.0.10',
    read: _readRemoteHost,
  ),
  _FieldCase(
    name: '远程端口',
    row: '远程执行',
    label: '端口',
    newText: '2222',
    expectedNew: 2222,
    read: _readRemotePort,
  ),
  _FieldCase(
    name: '远程用户',
    row: '远程执行',
    label: '用户',
    newText: 'admin',
    expectedNew: 'admin',
    read: _readRemoteUser,
  ),
  _FieldCase(
    name: '远程密码',
    row: '远程执行',
    label: '密码',
    newText: 'pw2',
    expectedNew: 'pw2',
    read: _readRemotePassword,
  ),
  _FieldCase(
    name: '私钥路径',
    row: '远程执行',
    label: '私钥路径',
    newText: '/home/ubuntu/.ssh/id_rsa',
    expectedNew: '/home/ubuntu/.ssh/id_rsa',
    read: _readRemoteKeyPath,
  ),
  _FieldCase(
    name: 'VLESS 链接',
    row: 'VLESS 链接',
    label: 'VLESS 链接',
    newText: 'vless://uuid@c.example:443?type=xhttp',
    expectedNew: 'vless://uuid@c.example:443?type=xhttp',
    read: _readVlessLinks,
  ),
];

int _readSha1(AppSettings s) => s.sha1Concurrency;
int _readLatencyConcurrency(AppSettings s) => s.latencyConcurrency;
int _readSpeedConcurrency(AppSettings s) => s.speedConcurrency;
int _readMaxLatency(AppSettings s) => s.maxLatency;
int _readDialTimeout(AppSettings s) => s.dialTimeout;
int _readDownloadTimeout(AppSettings s) => s.downloadTimeout;
String _readSpeedUrl(AppSettings s) => s.speedUrl;
String _readLatencyUrl(AppSettings s) => s.latencyUrl;
String _readGithubRepo(AppSettings s) => s.githubRepo;
String _readGithubToken(AppSettings s) => s.githubToken;
String _readRemoteHost(AppSettings s) => s.remoteHost;
int _readRemotePort(AppSettings s) => s.remotePort;
String _readRemoteUser(AppSettings s) => s.remoteUser;
String _readRemotePassword(AppSettings s) => s.remotePassword;
String _readRemoteKeyPath(AppSettings s) => s.remoteKeyPath;
String _readVlessLinks(AppSettings s) => s.vlessLinks.join('|');

void _expectOthersUntouched(
  AppSettings actual,
  AppSettings expected,
  List<_FieldCase> edited, {
  String where = '内存里的 settings',
}) {
  for (final other in _allFields) {
    if (edited.any((e) => identical(e, other))) continue;
    expect(
      other.read(actual),
      other.read(expected),
      reason: '$where 里「${other.name}」被这次保存抹掉了：'
          '用户只改了 ${edited.map((e) => '「${e.name}」').join('、')}，'
          '其余字段必须保持原值',
    );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  // =========================================================== 1. 只写脏字段
  //
  // 这一组刻意把「绑定时序」拆掉：页面从头到尾没收到「读完盘了」的通知，
  // 于是表单里全是默认值（真实 bug 的最坏形态）。此时只改一个字段保存，
  // 其余字段仍必须是磁盘上的值 —— 这条护栏必须**独立**成立，
  // 不能靠「绑定时机修好了」顺带遮住。
  group('护栏 · 绑定完全失败时也只写脏字段', () {
    testWidgets('页面从未收到读完盘的通知：只改「连接超时」，其余 15 个字段不受影响', (tester) async {
      _tallViewport(tester);
      final state = AppState(); // booting 仍为 true：页面永远等不到那次同步
      final expected = _storedSettings();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      // 真实时序：页面先挂载（settings 还是默认值），磁盘配置在之后才读出来，
      // 而且这里**故意不发通知** —— 页面永远不知道「读完了」。
      state.settings = _storedSettings();
      await tester.pump();

      // 先证明「绑定确实失败了」：表单里是默认值，不是磁盘值。
      await _openGroup(tester, '速度测试地址');
      expect(
        tester.widget<TextField>(_fieldByLabel('速度测试地址')).controller?.text,
        Defaults.speedUrl,
        reason: '前置条件：表单里应是默认值（绑定失败），否则这组测试没有意义',
      );
      await _closeSheet(tester);

      await _openGroup(tester, '超时');
      await tester.enterText(_fieldByLabel('连接超时（秒）'), '9');
      await _closeSheet(tester);
      await _tapSave(tester);

      expect(state.settings.dialTimeout, 9, reason: '改的那个字段必须生效');
      _expectOthersUntouched(state.settings, expected, <_FieldCase>[_allFields[4]]);

      final disk = await _readDisk(tester);
      expect(disk.dialTimeout, 9);
      _expectOthersUntouched(disk, expected, <_FieldCase>[_allFields[4]],
          where: '落盘的 JSON');
    });

    testWidgets('同一条护栏在自动保存路径上也成立（改「指纹并发」，等去抖）', (tester) async {
      _tallViewport(tester);
      final state = AppState();
      final expected = _storedSettings();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();
      state.settings = _storedSettings();
      await tester.pump();

      await _openGroup(tester, '并发');
      await tester.enterText(_fieldByLabel('指纹筛选并发'), '33');
      // 不点保存、不关弹层：只让 600ms 去抖自己触发。
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();

      expect(state.settings.sha1Concurrency, 33);
      _expectOthersUntouched(state.settings, expected, <_FieldCase>[_allFields[0]]);

      await _closeSheet(tester);
      final disk = await _readDisk(tester);
      expect(disk.sha1Concurrency, 33);
      _expectOthersUntouched(disk, expected, <_FieldCase>[_allFields[0]],
          where: '落盘的 JSON');
    });
  });

  // =============================================== 2. 16 个字段逐个覆盖（表驱动）
  //
  // 第一风险：`_applyField` 的 16 个分支漏一个，那个字段就永远存不上。
  // 每个用例都走「改它 → 保存 → 其余 15 个不变」的完整闭环；
  // 漏分支 / 写错分支都会让对应用例红（变异验证见报告）。
  group('护栏 · 16 个字段逐个覆盖', () {
    for (final c in _allFields) {
      testWidgets('改「${c.name}」保存：它生效，其余 15 个仍是磁盘值', (tester) async {
        _tallViewport(tester);
        final state = AppState()..booting = false;
        final expected = _storedSettings();
        state.settings = _storedSettings();
        await tester.pumpWidget(_host(state));
        await tester.pumpAndSettle();

        await _openGroup(tester, c.row);
        await tester.enterText(_fieldByLabel(c.label), c.newText);
        await _closeSheet(tester);
        await _tapSave(tester);

        expect(c.read(state.settings), c.expectedNew,
            reason: '「${c.name}」没有写进 settings',);
        _expectOthersUntouched(state.settings, expected, <_FieldCase>[c]);

        final disk = await _readDisk(tester);
        expect(c.read(disk), c.expectedNew,
            reason: '「${c.name}」没有真正落盘（重启后用户就会看到「配置丢了」）',);
        _expectOthersUntouched(disk, expected, <_FieldCase>[c],
            where: '落盘的 JSON');
      });
    }
  });

  // ==================================================== 3. 去抖：不抖、不并发
  group('自动保存 · 去抖与串行', () {
    testWidgets('连续快速输入 5 次：只落盘 1 次，且落的是最后一次的值', (tester) async {
      _tallViewport(tester);
      final state = _CountingState()..booting = false;
      state.settings = _storedSettings();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, '并发');
      for (final text in <String>['30', '31', '32', '33', '34']) {
        await tester.enterText(_fieldByLabel('指纹筛选并发'), text);
        // 每次只推进 100ms 假时钟：远小于 600ms 去抖窗口，且**没有真实等待**。
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(state.saves, 0,
          reason: '输入还没停顿 600ms，一次都不该落盘（去抖窗口内）',);

      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(state.saves, 1, reason: '5 次输入只应产生 1 次落盘');
      expect(state.settings.sha1Concurrency, 34);

      await _closeSheet(tester);
      expect(state.saves, 1, reason: '关弹层时已无脏字段，不该再写一次');
      final disk = await _readDisk(tester);
      expect(disk.sha1Concurrency, 34, reason: '落盘的必须是最后一次输入的值');
    });

    testWidgets('手动保存与自动保存撞车：串行执行，后完成者不会覆盖先完成者的新改动', (tester) async {
      _tallViewport(tester);
      final expected = _storedSettings();
      final state = _GatedState()..booting = false;
      state.settings = _storedSettings();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      // 第一次落盘被闸门卡住（模拟真机上 setString 慢）。
      await _openGroup(tester, '并发');
      await tester.enterText(_fieldByLabel('指纹筛选并发'), '33');
      await _closeSheet(tester); // 关弹层 → _flushPending 立刻入队第一笔保存
      expect(state.snapshots, isNotEmpty,
          reason: '第一笔保存应该已经开始（否则闸门没卡住任何东西）',);

      // 第一笔还在写的时候，用户又改了另一个字段，并手动点了保存。
      await _openGroup(tester, '超时');
      await tester.enterText(_fieldByLabel('下载超时（秒）'), '22');
      await _closeSheet(tester);
      await _tapSave(tester);

      // 放行闸门，让排队的保存依次完成。
      state.openGate();
      await tester.pumpAndSettle();

      // 串行证据：写入序列必须是 start/end 严格交替，不能出现两次 start 相邻。
      for (var i = 0; i < state.order.length; i++) {
        expect(state.order[i], i.isEven ? 'start' : 'end',
            reason: '保存必须串行（两笔同时写 = 整份 JSON 覆盖写，先完成的会被吞掉）：'
                '${state.order}',);
      }

      final last = state.snapshots.last;
      expect(last['sha1Concurrency'], 33, reason: '最后一笔必须带着前一笔的改动');
      expect(last['downloadTimeout'], 22, reason: '最后一笔必须带着改过的字段');

      // 不倒退：某字段一旦写成新值，后续任何一笔都不能把它写回旧值。
      var sawSha1New = false;
      var sawDownloadNew = false;
      for (final snap in state.snapshots) {
        if (sawSha1New) {
          expect(snap['sha1Concurrency'], 33, reason: '后续保存把指纹并发写回了旧值');
        }
        if (sawDownloadNew) {
          expect(snap['downloadTimeout'], 22, reason: '后续保存把下载超时写回了旧值');
        }
        sawSha1New = sawSha1New || snap['sha1Concurrency'] == 33;
        sawDownloadNew = sawDownloadNew || snap['downloadTimeout'] == 22;
      }

      final disk = await _readDisk(tester);
      expect(disk.sha1Concurrency, 33);
      expect(disk.downloadTimeout, 22);
      _expectOthersUntouched(disk, expected, <_FieldCase>[_allFields[0], _allFields[5]],
          where: '落盘的 JSON');
    });
  });

  // ==================================================== 4. 不许有保存↔通知 回环
  group('自动保存 · 没有保存↔通知的回环', () {
    testWidgets('读完盘后的同步不会触发自动保存；再等 5 秒也没有写盘风暴', (tester) async {
      _tallViewport(tester);
      final state = _CountingState(); // booting = true
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();
      expect(state.saves, 0);

      // boot 完成：settings 换成磁盘配置并通知。
      state.settings = _storedSettings();
      state.booting = false;
      state.notifyListeners();
      await tester.pumpAndSettle();

      // 表单必须跟上磁盘值（同步发生了）……
      await _openGroup(tester, '速度测试地址');
      expect(
        tester.widget<TextField>(_fieldByLabel('速度测试地址')).controller?.text,
        'https://example.com/500.zip',
      );
      await _closeSheet(tester);

      // 列表型字段也要按「一行一条」正确回填（`_textOf` 的 List 分支）：
      // 这里错了不会报错，只会把两条链接粘成一条垃圾链接。
      await _openGroup(tester, 'VLESS 链接');
      expect(
        tester.widget<TextField>(_fieldByLabel('VLESS 链接')).controller?.text,
        'vless://uuid@a.example:443?type=xhttp\n'
        'vless://uuid@b.example:443?type=xhttp',
        reason: '多行字段的回填必须按行拼接，否则两条链接会粘成一条',);
      await _closeSheet(tester);

      // ……但「同步」本身不能被当成用户编辑而触发一次落盘。
      expect(state.saves, 0,
          reason: '程序化回填 controller 时若没有抑制，会被自己的监听器当成用户输入，'
              '形成 保存→notifyListeners→同步→保存 的回环',);

      // 上界断言：给足 5 秒假时间，落盘次数必须还是 0。
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(state.saves, 0, reason: '5 秒内不应出现任何一次多余落盘（写盘风暴）');
    });

    testWidgets('一次自动保存之后，5 秒内落盘次数上界为 1', (tester) async {
      _tallViewport(tester);
      final state = _CountingState()..booting = false;
      state.settings = _storedSettings();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, '并发');
      await tester.enterText(_fieldByLabel('指纹筛选并发'), '33');
      await _closeSheet(tester);
      await tester.pumpAndSettle();
      expect(state.saves, 1);

      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(state.saves, 1, reason: '保存成功后的 notifyListeners 不该再引发第二次落盘');
    });
  });

  // ============================================================ 5. dispose 路径
  group('自动保存 · 页面销毁时抢救未落盘的改动', () {
    /// 输入后**不关弹层**直接销毁整棵树：此刻改动只存在于 600ms 去抖器里，
    /// 只有 dispose 那条路径能救它。
    Future<_CountingState> typeThenDispose(WidgetTester tester) async {
      final state = _CountingState()..booting = false;
      state.settings = _storedSettings();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, '超时');
      await tester.enterText(_fieldByLabel('连接超时（秒）'), '9');
      await tester.pump(const Duration(milliseconds: 100)); // 仍在去抖窗口内

      // 销毁页面（等价于路由被弹掉 / 测试换树）。
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      return state;
    }

    testWidgets('输入后立刻销毁页面：pending 改动仍然落盘', (tester) async {
      _tallViewport(tester);
      final state = await typeThenDispose(tester);

      expect(state.settings.dialTimeout, 9, reason: '关闭前应已写进内存');
      final disk = await _readDisk(tester);
      expect(disk.dialTimeout, 9,
          reason: '「改完直接切走」是用户报的主场景；销毁时没落盘就等于没保存',);
    });

    testWidgets('销毁路径不得读取已 dispose 的 controller（不抛异常、不静默失败）', (tester) async {
      _tallViewport(tester);
      final state = await typeThenDispose(tester);

      expect(tester.takeException(), isNull,
          reason: 'dispose 之后的保存必须用「关闭前同步读出的快照」，'
              '不能再去碰已销毁的 TextEditingController',);
      expect(
        state.logs.where((l) => l.contains('保存失败')).toList(),
        isEmpty,
        reason: '销毁路径上的保存失败也必须进日志；这里要求它根本没失败：${state.logs}',
      );
    });
  });

  // ======================================================== 6. 失败必须可见
  group('保存失败 · 自检与提示不是花架子', () {
    testWidgets('saveSettings 不真正写盘：界面明确报「对不上」，不许静默成功', (tester) async {
      _tallViewport(tester);
      final state = _SilentDropState()..booting = false;
      state.settings = _storedSettings();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, '并发');
      await tester.enterText(_fieldByLabel('指纹筛选并发'), '33');
      await _closeSheet(tester);
      await _tapSave(tester);

      expect(find.textContaining('对不上'), findsWidgets,
          reason: '写成功但没真正持久化，必须当场告警，而不是留到下次启动才发现',);
      expect(find.text('设置已保存'), findsNothing, reason: '不能同时给出「已保存」的假象');
      expect(state.logs.any((l) => l.contains('对不上')), isTrue,
          reason: '日志里也要留痕，否则用户报「保存没反应」时无从查起',);
    });

    testWidgets('落盘抛异常：提示 + 日志都要有（不能静默）', (tester) async {
      _tallViewport(tester);
      final state = _FailingState()..booting = false;
      state.settings = _storedSettings();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, '并发');
      await tester.enterText(_fieldByLabel('指纹筛选并发'), '33');
      await _closeSheet(tester);
      await _tapSave(tester);

      expect(find.textContaining('保存失败'), findsWidgets);
      expect(state.logs.any((l) => l.contains('保存失败')), isTrue);
    });

    testWidgets('自检覆盖全部 16 个字段：只丢一个不常见的字段也要抓得到', (tester) async {
      _tallViewport(tester);
      // 写盘「成功」，但把远程端口偷偷写成旧值：这是插件级静默丢写的典型形态。
      // 旧实现只比对 8 个关键字段，remotePort 不在其中 → 会静默通过。
      final state = _DropsRemotePortState()..booting = false;
      state.settings = _storedSettings();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, '远程执行');
      await tester.enterText(_fieldByLabel('端口'), '2222');
      await _closeSheet(tester);
      await _tapSave(tester);

      expect(find.textContaining('对不上'), findsWidgets,
          reason: '端口没写进去必须当场报出来',);
      expect(find.textContaining('远程端口'), findsWidgets,
          reason: '提示要指名是哪个字段丢了，否则用户/排障者只能全表重填',);
      expect(find.text('设置已保存'), findsNothing);
    });

    testWidgets('自检不许误报：用户主动把值设成「旧默认值」也要能正常存', (tester) async {
      _tallViewport(tester);
      // maxLatency=200、speedConcurrency=2 恰好是历史默认值，AppSettings.load()
      // 里有一次性迁移。写入时 toJson 会打上「已迁移」标记，读回来就不该再被改成
      // 0 / 3 —— 否则自检会把「用户自己填的 200」误判成「没写进去」，
      // 用户每次保存都要看到一个根本不存在的问题。
      final state = AppState()..booting = false;
      state.settings = _storedSettings()
        ..maxLatency = 200
        ..speedConcurrency = 2;
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, '并发');
      await tester.enterText(_fieldByLabel('指纹筛选并发'), '33');
      await _closeSheet(tester);
      await _tapSave(tester);

      expect(find.textContaining('对不上'), findsNothing,
          reason: '这是误报：磁盘上的 200 / 2 与内存一致',);
      final disk = await _readDisk(tester);
      expect(disk.sha1Concurrency, 33,
          reason: '前置条件：这次保存本身必须成功（否则 findsNothing 是空转）',);
      expect(disk.maxLatency, 200, reason: '用户自己填的 200 不能被迁移改掉');
      expect(disk.speedConcurrency, 2);
    });

    // ---------------------------------------------------------------
    // R1 回归（曾是一个真实缺陷，已修，现在钉住不许回来）
    //
    // 历史故障：`_saveNow` 曾在 `await _state.saveSettings()` **之前**就执行
    // `_snapshot = form`。于是落盘一旦失败：
    //   1. 内存里 settings 已被 `_applyField` 改成新值（33）；
    //   2. `_snapshot` 也已推进成新值 → `_dirtyFields()` 变空 → 再点「保存」
    //      走 `dirty.isEmpty` 分支，只提示「没有需要保存的改动」，**根本不重试**；
    //   3. dispose 里 `_dirtyFields().isEmpty` 同样为真 → 也不会抢救。
    // 结果：磁盘永远是旧值，用户重启后看到的就是「我明明保存了，配置却丢了」。
    //
    // 修法：`_snapshot` 只在「写盘成功 + 回读校验通过」之后才推进（乐观写入保留，
    // 因为 `_applyField` 幂等，重试会重新提交同一批脏字段）。
    // 验收方式：把 `_snapshot = form;` 挪回 await 之前（变异），本用例必须红。
    // ---------------------------------------------------------------
    testWidgets('落盘失败后再点保存：会真的重试写回，改动不会丢', (tester) async {
      _tallViewport(tester);
      final state = _FailOnceState()..booting = false;
      state.settings = _storedSettings();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, '并发');
      await tester.enterText(_fieldByLabel('指纹筛选并发'), '33');
      await _closeSheet(tester); // 第一笔保存被拒绝
      expect(state.attempts, 1);
      expect(state.logs.any((l) => l.contains('保存失败')), isTrue,
          reason: '第一次失败必须可见（这条现状是对的）',);
      // 文案说「改动没丢、再点会重试」——这句话必须是真的，
      // 后面两步（再点保存 → 真的写盘成功）就是在验它不是空话。
      expect(find.textContaining('改动没丢'), findsWidgets,
          reason: '失败提示必须给出下一步动作，否则用户只能干等',);
      // 失败后内存必须回到「磁盘上确认存活的值」：否则摘要行显示新值、
      // 磁盘还是旧值，用户看到的是「已经存上了」的假象。
      expect(state.settings.sha1Concurrency, 45,
          reason: '写盘失败就不能让内存领先磁盘（乐观写入要退回），'
              '否则摘要行在骗人',);

      // 用户看到「保存失败」后，再点一次「保存」重试。
      await _tapSave(tester);

      expect(state.attempts, greaterThan(1),
          reason: '第二次点击必须真的再写一次盘，不能因为快照已推进就跳过',);
      final disk = await _readDisk(tester);
      expect(disk.sha1Concurrency, 33,
          reason: '重试成功后磁盘必须是新值；否则用户的改动被静默丢弃',);
    });
  });

  // ================================================ 7. 既有语义 / 行为未退化
  group('既有语义未退化', () {
    testWidgets('两条地址清空后都回落默认值（speedUrl / latencyUrl 对称）', (tester) async {
      _tallViewport(tester);
      final state = AppState()..booting = false;
      state.settings = _storedSettings();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, '速度测试地址');
      await tester.enterText(_fieldByLabel('速度测试地址'), '');
      await _closeSheet(tester);
      await _tapSave(tester);

      await _openGroup(tester, '延迟测试地址');
      await tester.enterText(_fieldByLabel('延迟测试地址'), '');
      await _closeSheet(tester);
      await _tapSave(tester);

      expect(state.settings.speedUrl, Defaults.speedUrl,
          reason: '空的速度地址会让三阶段下载直接报配置错误，语义是「恢复默认」',);
      expect(state.settings.latencyUrl, Defaults.latencyUrl,
          reason: '空地址会让每条线路报「地址非法」，语义是「恢复默认」',);

      final disk = await _readDisk(tester);
      expect(disk.speedUrl, Defaults.speedUrl);
      expect(disk.latencyUrl, Defaults.latencyUrl);
    });

    testWidgets('仓库地址粘网页链接：只写脏字段的新路径仍会规范化并回填', (tester) async {
      _tallViewport(tester);
      final state = AppState()..booting = false;
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, 'GitHub 推送');
      await tester.enterText(
        _fieldByLabel('仓库地址'),
        'https://github.com/0-RTT/sub.git',
      );
      await _closeSheet(tester);
      await _tapSave(tester);

      expect(state.settings.githubRepo, '0-RTT/sub');
      await _openGroup(tester, 'GitHub 推送');
      expect(
        tester.widget<TextField>(_fieldByLabel('仓库地址')).controller?.text,
        '0-RTT/sub',
        reason: '用户要看到真正生效的 owner/repo',);
    });

    testWidgets('仓库地址没输完：自动保存静默跳过（不落盘、不弹 SnackBar）', (tester) async {
      _tallViewport(tester);
      final state = _CountingState()..booting = false;
      state.settings = _storedSettings();
      await tester.pumpWidget(_host(state));
      await tester.pumpAndSettle();

      await _openGroup(tester, 'GitHub 推送');
      // 只有 owner、没有 repo：格式不完整。
      await tester.enterText(_fieldByLabel('仓库地址'), 'https://github.com/0-RTT');
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();

      expect(state.saves, 0, reason: '仓库地址没输完时不该落库');
      expect(find.textContaining('暂不自动保存'), findsOneWidget,
          reason: '只在状态栏说一声',);
      expect(find.textContaining('格式不对'), findsNothing,
          reason: '自动保存阶段不该弹 SnackBar 打断输入',);
      expect(state.settings.githubRepo, 'acme/sub', reason: '磁盘上的旧值不能被抹掉');

      await _closeSheet(tester);
      expect(state.settings.githubRepo, 'acme/sub');
    });
  });
}
