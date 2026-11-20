import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cytest/core/settings.dart';
import 'package:cytest/data/link_probe.dart';
import 'package:cytest/data/link_test.dart';
import 'package:cytest/data/vless.dart';
import 'package:cytest/data/xray.dart';
import 'package:cytest/state/app_state.dart';

/// 「默认延迟阈值 200 → 0」的一次性迁移。
///
/// 背景：`maxLatency` 的语义是「一键测试时跳过太慢的候选、省测速时间」，
/// 不负责判定节点可用。延迟口径改成「HTTP 响应头到达」之后，200ms 会把
/// 大量跨境但能用的候选整批筛掉，用户看到的就是「一键测试全部失败」。
///
/// 只改 `Defaults` 是不够的 —— 老用户的 `200` 早就落盘了，必须迁移。
/// 这里的四条断言就是迁移的全部契约：
///   1) 老的 200 且无标记 → 迁到 0；
///   2) 用户自己设过的值（1500）→ 一律不动；
///   3) 已有迁移标记 + 200 → 保留 200（用户后来手动设的，尊重他）；
///   4) 落盘时必须写上标记，否则下次启动又会把 200 改掉（迁移不再一次性）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Settings · maxLatency 默认值迁移', () {
    test('默认值已改为 0（不限），旧默认 200 单独留作迁移识别', () {
      expect(Defaults.maxLatency, 0,
          reason: '阈值不该承担「判定失败」的职责，默认必须是不限');
      expect(Defaults.legacyMaxLatency, 200,
          reason: '迁移要靠旧默认值识别老数据，别顺手改掉它');
    });

    test('老数据 {"maxLatency":200} 无迁移标记 → 读出来是 0', () {
      final s = AppSettings.fromJson(<String, dynamic>{'maxLatency': 200});
      expect(s.maxLatency, 0);
      expect(s.latencyThresholdMigrated, isTrue,
          reason: '读进来的这份必须算「已迁移」，否则下次启动还会再迁一次');
    });

    test('老数据 {"maxLatency":1500} → 保持 1500（不被迁移覆盖）', () {
      final s = AppSettings.fromJson(<String, dynamic>{'maxLatency': 1500});
      expect(s.maxLatency, 1500, reason: '用户明确设过的值必须尊重');
    });

    test('带标记且 maxLatency=200 → 保持 200（用户后来手动设的）', () {
      final s = AppSettings.fromJson(<String, dynamic>{
        'maxLatency': 200,
        'latencyThresholdMigrated': true,
      });
      expect(s.maxLatency, 200,
          reason: '迁移只做一次；打完标记后用户填 200 就是他自己的选择');
    });

    test('落盘写 latencyThresholdMigrated: true，再读回来仍是 200 不再被迁移', () {
      // 模拟：用户自己把阈值设成 200 后保存 → 落盘 → 下次启动
      final saved = AppSettings(maxLatency: 200).toJson();
      expect(saved['latencyThresholdMigrated'], isTrue,
          reason: '不写标记的话，用户手填的 200 会在下次启动被静默改回 0');

      final reloaded = AppSettings.fromJson(saved);
      expect(reloaded.maxLatency, 200);
    });

    test('全新安装（没有存量 json）走默认 0，且落盘即带标记', () {
      final fresh = AppSettings();
      expect(fresh.maxLatency, 0);
      expect(fresh.toJson()['latencyThresholdMigrated'], isTrue);
      // 落盘再读回来还是 0
      expect(AppSettings.fromJson(fresh.toJson()).maxLatency, 0);
    });

    test('其它字段不受迁移影响（不要因为改一处丢掉整份设置）', () {
      final s = AppSettings.fromJson(<String, dynamic>{
        'maxLatency': 200,
        'speedUrl': 'https://example.com/1.zip',
        'dialTimeout': 9,
        'downloadTimeout': 21,
        'httpProxy': 'http://127.0.0.1:10809',
      });
      expect(s.maxLatency, 0);
      expect(s.speedUrl, 'https://example.com/1.zip');
      expect(s.dialTimeout, 9);
      expect(s.downloadTimeout, 21);
      expect(s.httpProxy, 'http://127.0.0.1:10809');
    });
  });

  // 真实风险：存量 json 里的整数被写成 `200.0`（double）时，`as int?` 会抛
  // TypeError → `load()` 的 catch 兜成 `AppSettings()` → **用户整份设置静默
  // 恢复默认**（代理、Token、订阅全没了）。所以数值字段一律 `num?.toInt()`。
  group('Settings · 数值字段容错（double 落盘不能把整份设置打回默认）', () {
    test('{"maxLatency":200.0} 且已迁移 → 读出 200，其它数值字段同样容错', () {
      final s = AppSettings.fromJson(<String, dynamic>{
        'maxLatency': 200.0,
        'latencyThresholdMigrated': true,
        'dialTimeout': 9.0,
        'downloadTimeout': 21.0,
        'sha1Concurrency': 12.0,
        'latencyConcurrency': 50.0,
        'speedConcurrency': 4.0,
        'remotePort': 2222.0,
        'speedUrl': 'https://example.com/1.zip',
      });
      expect(s.maxLatency, 200);
      expect(s.dialTimeout, 9);
      expect(s.downloadTimeout, 21);
      expect(s.sha1Concurrency, 12);
      expect(s.latencyConcurrency, 50);
      expect(s.speedConcurrency, 4);
      expect(s.remotePort, 2222);
      expect(s.speedUrl, 'https://example.com/1.zip');
    });

    test('{"maxLatency":200.0} 未迁移 → 迁移照旧生效（0），但不会连坐其它字段', () {
      final s = AppSettings.fromJson(<String, dynamic>{
        'maxLatency': 200.0,
        'httpProxy': 'http://127.0.0.1:10809',
      });
      expect(s.maxLatency, 0,
          reason: 'double 的 200 仍是旧默认值，迁移逻辑不区分 int/double');
      expect(s.httpProxy, 'http://127.0.0.1:10809',
          reason: '不能因为一个 double 把代理也丢了');
    });

    // lead 指定的专项用例：double 落盘时不能走 load() 的重置分支，
    // 否则用户丢的是全部配置（vlessLinks / token / 代理），不只一个阈值。
    test('{"maxLatency":200.0,"vlessLinks":[...]} → 200 且 vlessLinks 不丢', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cytest.settings.v1': '{"maxLatency":200.0,'
            '"latencyThresholdMigrated":true,'
            '"vlessLinks":["vless://x"],'
            '"githubToken":"ghp_secret",'
            '"httpProxy":"http://127.0.0.1:10809"}',
      });
      final s = await AppSettings.load();
      expect(s.maxLatency, 200, reason: 'double 200.0 应被 toInt() 成 200');
      expect(s.vlessLinks, <String>['vless://x'],
          reason: '走到重置分支的话这里会变成空列表');
      expect(s.githubToken, 'ghp_secret');
      expect(s.httpProxy, 'http://127.0.0.1:10809');
    });

    test('load() 读 double 落盘：不抛错、不整份重置', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cytest.settings.v1':
            '{"maxLatency":200.0,"latencyThresholdMigrated":true,'
                '"dialTimeout":9.0,"downloadTimeout":21.0,'
                '"httpProxy":"http://127.0.0.1:10809",'
                '"speedUrl":"https://example.com/1.zip"}',
      });
      final s = await AppSettings.load();
      expect(s.maxLatency, 200, reason: 'double 200.0 应被 toInt() 成 200');
      expect(s.dialTimeout, 9);
      expect(s.downloadTimeout, 21);
      expect(s.httpProxy, 'http://127.0.0.1:10809',
          reason: '整份设置不能被一个 double 打回默认');
      expect(s.speedUrl, 'https://example.com/1.zip');
    });

    test('load() 只有真正无法解析时才回退默认（对照组）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cytest.settings.v1': 'not-json',
      });
      final s = await AppSettings.load();
      expect(s.maxLatency, Defaults.maxLatency);
      expect(s.httpProxy, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // 延迟 / 速度两个地址必须是两条独立的口径，且老数据能平滑过渡。
  // -------------------------------------------------------------------------
  group('Settings · 延迟地址（latencyUrl）', () {
    test('Defaults 与 link_probe 的常量逐字一致（改一处漏一处会红）', () {
      expect(Defaults.latencyUrl, kDefaultLatencyUrl);
      expect(Defaults.speedUrl, kDefaultSpeedUrl);
      expect(Defaults.latencyUrl, isNot(Defaults.speedUrl));
    });

    test('老 JSON 没有 latencyUrl 键 → 回落默认小端点（不是空串）', () {
      final s = AppSettings.fromJson(<String, dynamic>{
        'speedUrl': 'https://example.com/big.zip',
      });

      expect(s.latencyUrl, Defaults.latencyUrl);
      expect(s.speedUrl, 'https://example.com/big.zip', reason: '速度地址不受影响');
    });

    test('latencyUrl 为空白 / null / 非字符串 → 一律回落默认', () {
      expect(AppSettings.fromJson(<String, dynamic>{'latencyUrl': '   '}).latencyUrl,
          Defaults.latencyUrl);
      expect(AppSettings.fromJson(<String, dynamic>{'latencyUrl': null}).latencyUrl,
          Defaults.latencyUrl);
      expect(AppSettings.fromJson(<String, dynamic>{'latencyUrl': 42}).latencyUrl,
          Defaults.latencyUrl);
    });

    test('toJson 必须写回 latencyUrl（漏写 → 保存一次就把设置冲掉）', () {
      final s = AppSettings()
        ..speedUrl = 'https://s.example.com/big.zip'
        ..latencyUrl = 'https://l.example.com/generate_204';

      final json = s.toJson();
      expect(json['latencyUrl'], 'https://l.example.com/generate_204');

      final restored = AppSettings.fromJson(json);
      expect(restored.latencyUrl, 'https://l.example.com/generate_204');
      expect(restored.speedUrl, 'https://s.example.com/big.zip');
    });

    test('落盘再 load 一轮：两个地址都保真', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final s = AppSettings()
        ..speedUrl = 'https://s.example.com/big.zip'
        ..latencyUrl = 'https://l.example.com/generate_204';
      await s.save();

      final loaded = await AppSettings.load();
      expect(loaded.speedUrl, 'https://s.example.com/big.zip');
      expect(loaded.latencyUrl, 'https://l.example.com/generate_204');
    });

    test('boot 后设置里的两个地址真的灌进了 runner（否则设置页是摆设）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cytest.settings.v1': '{"speedUrl":"https://s.example.com/big.zip",'
            '"latencyUrl":"https://l.example.com/generate_204"}',
      });
      final runner = LinkTestRunner(xray: _FakeXray());
      final state = AppState(runner: runner);

      await state.boot();

      expect(runner.speedUrl, 'https://s.example.com/big.zip');
      expect(runner.latencyUrl, 'https://l.example.com/generate_204');
    });
  });
}

/// 只为构造 AppState 用的空壳批量启动器（boot 不会碰它）。
class _FakeXray implements BatchXray {
  @override
  XrayMode mode = XrayMode.none;

  @override
  Future<String?> startBatch(List<(Vless, int)> nodes) async => 'unused';

  @override
  Future<void> stop() async {}
}
