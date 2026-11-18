// QA 独立验证：maxLatency 默认值迁移的「真实落盘路径」。
//
// 工程师的 test/settings_migration_test.dart 只在 fromJson/toJson 层面断言，
// 没有走 SharedPreferences 的真实读写路径（load() / save() / jsonEncode）。
// 这里补上那一层，重点验证一条他容易漏的场景：
//   迁移标记已经落盘 → 用户手动把值改回 200 → 重读必须保持 200，
//   不能被「恰好等于 200」的迁移规则再改成 0。
//
// 跑法：flutter test test/qa_migration_persist_test.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cytest/core/settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 与 AppSettings._key 一致（私有常量，测试里只能重写字符串）。
  const key = 'cytest.settings.v1';

  Future<String> rawStored() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key)!;
  }

  test('老用户落盘 200（无标记）→ load 得到 0，save 后落盘带标记', () async {
    SharedPreferences.setMockInitialValues({
      key: jsonEncode(<String, dynamic>{'maxLatency': 200}),
    });

    final s = await AppSettings.load();
    expect(s.maxLatency, 0, reason: '200 是旧默认值，必须被迁到 0（不限）');

    await s.save();
    final stored = jsonDecode(await rawStored()) as Map<String, dynamic>;
    expect(stored['maxLatency'], 0);
    expect(stored['latencyThresholdMigrated'], isTrue,
        reason: '迁移必须落标记，否则下次启动还会再迁一次');
  });

  test('已迁移落盘 → 用户手动改成 200 并保存 → 重读仍是 200', () async {
    SharedPreferences.setMockInitialValues({
      key: jsonEncode(<String, dynamic>{
        'maxLatency': 0,
        'latencyThresholdMigrated': true,
      }),
    });

    final s = await AppSettings.load();
    expect(s.maxLatency, 0);
    s.maxLatency = 200; // 用户在设置页手动填 200
    await s.save();

    final again = await AppSettings.load();
    expect(again.maxLatency, 200,
        reason: '打了标记之后，200 就是用户自己的选择，绝不能被静默改回 0');
  });

  test('全新安装（无任何存量）→ 默认 0，首次 save 即带标记', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final s = await AppSettings.load();
    expect(s.maxLatency, 0);

    await s.save();
    final stored = jsonDecode(await rawStored()) as Map<String, dynamic>;
    expect(stored['maxLatency'], 0);
    expect(stored['latencyThresholdMigrated'], isTrue);
  });

  test('迁移只认 200：1500 / 50 落盘后原样保留', () async {
    for (final v in <int>[1500, 50]) {
      SharedPreferences.setMockInitialValues({
        key: jsonEncode(<String, dynamic>{'maxLatency': v}),
      });
      final s = await AppSettings.load();
      expect(s.maxLatency, v, reason: '用户设过的 $v 必须尊重');
    }
  });

  // 跨端写盘：JSON 里 200.0 是合法写法（Python / Kotlin / 其它端可能这么写）。
  // 早期实现 `json['maxLatency'] as int?` 会抛类型错，被 load() 的 catch 吞掉后
  // 返回 AppSettings()，用户的整份设置静默恢复默认 —— 比迁移本身危险得多。
  test('落盘值是 double（200.0 / 1500.5）时不抛错、不被重置整份设置', () async {
    SharedPreferences.setMockInitialValues({
      key: jsonEncode(<String, dynamic>{
        'maxLatency': 200.0,
        'speedUrl': 'https://example.com/d.zip',
      }),
    });
    final s = await AppSettings.load();
    expect(s.maxLatency, 0, reason: '200.0 等价于旧默认 200，应当迁移');
    expect(s.speedUrl, 'https://example.com/d.zip',
        reason: '不能因为类型转换失败把整份设置丢回默认值');

    SharedPreferences.setMockInitialValues({
      key: jsonEncode(<String, dynamic>{'maxLatency': 1500.5}),
    });
    final s2 = await AppSettings.load();
    expect(s2.maxLatency, 1500, reason: '非整数值向下取整保留，不应被迁移');
  });

  // 跨端写盘可能把「所有」数值都写成 double（Python json.dump(5.0) 就是 5.0）。
  // 只要有一个字段还用 `as int?`，整份设置就会被 load() 的 catch 吞掉回默认 ——
  // 用户感受是「升级后全部设置没了」，而且完全没有报错。
  test('所有数值字段都是 double 时，其它设置必须原样保留', () async {
    SharedPreferences.setMockInitialValues({
      key: jsonEncode(<String, dynamic>{
        'maxLatency': 200.0,
        'dialTimeout': 5.0,
        'downloadTimeout': 10.0,
        'sha1Concurrency': 30.0,
        'latencyConcurrency': 100.0,
        'speedConcurrency': 2.0,
        'remotePort': 2222.0,
        'speedUrl': 'https://example.com/x.zip',
        'remoteHost': '10.0.0.9',
        'httpProxy': 'http://127.0.0.1:10809',
        'githubToken': 'ghp_qa_token',
        'vlessLinks': <String>['vless://uuid@host:443#qa'],
      }),
    });

    final s = await AppSettings.load();
    expect(s.maxLatency, 0, reason: '200.0 等价于旧默认 200，应当被迁移');
    expect(s.dialTimeout, 5);
    expect(s.downloadTimeout, 10);
    expect(s.sha1Concurrency, 30);
    expect(s.latencyConcurrency, 100);
    // 2.0 等价于旧默认 2，按「从没改过」迁移到新默认 3（与 maxLatency 同一套做法）
    expect(s.speedConcurrency, Defaults.speedConcurrency,
        reason: '旧默认 2 会被一次性迁到 3');
    expect(s.speedConcurrencyMigrated, isTrue);
    expect(s.remotePort, 2222);
    expect(s.speedUrl, 'https://example.com/x.zip');
    expect(s.remoteHost, '10.0.0.9');
    expect(s.httpProxy, 'http://127.0.0.1:10809');
    expect(s.githubToken, 'ghp_qa_token');
    expect(s.vlessLinks, <String>['vless://uuid@host:443#qa'],
        reason: '任意一个字段转换抛错都会让上面所有断言一起变默认值');
  });

  // 真正损坏的数据：不许崩溃，按「回退默认」处理（允许丢这一份，但不许抛到 UI）。
  test('损坏的 json 走回退默认且不崩溃', () async {
    SharedPreferences.setMockInitialValues({
      key: jsonEncode(<String, dynamic>{'maxLatency': 'abc'}),
    });
    final s = await AppSettings.load();
    expect(s.maxLatency, Defaults.maxLatency);
    expect(s.speedUrl, Defaults.speedUrl, reason: '回退就是整份默认，可接受');

    SharedPreferences.setMockInitialValues({key: '{not json'});
    final s2 = await AppSettings.load();
    expect(s2.maxLatency, Defaults.maxLatency);
    expect(s2.dialTimeout, Defaults.dialTimeout);

    SharedPreferences.setMockInitialValues({
      key: jsonEncode(<String, dynamic>{'vlessLinks': 'not-a-list'}),
    });
    final s3 = await AppSettings.load();
    expect(s3.vlessLinks, isEmpty, reason: '类型不对时回退默认空列表，不许崩');
  });

  test('迁移不连坐其它字段（老数据整体仍可读）', () async {
    SharedPreferences.setMockInitialValues({
      key: jsonEncode(<String, dynamic>{
        'maxLatency': 200,
        'speedUrl': 'https://example.com/f.zip',
        'dialTimeout': 8,
        'httpProxy': 'http://127.0.0.1:10809',
        'vlessLinks': <String>['vless://a@b:443#n1'],
      }),
    });

    final s = await AppSettings.load();
    expect(s.maxLatency, 0);
    expect(s.speedUrl, 'https://example.com/f.zip');
    expect(s.dialTimeout, 8);
    expect(s.httpProxy, 'http://127.0.0.1:10809');
    expect(s.vlessLinks, <String>['vless://a@b:443#n1']);
  });
}
