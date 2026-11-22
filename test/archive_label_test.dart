import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/history.dart';

/// 存档名（`AS13335-20261120-234712`）在界面上的呈现。
///
/// 这条链路修过两次：记录页一度只显示时间，测试页的选择弹层又只显示时间。
/// 所以这里除了断言 [RecordInfo.label]，还守住「弹层必须用 label」——
/// 只测 label 是防不住「渲染时又写回 info.at」这种回退的。
void main() {
  group('RecordInfo.label', () {
    test('带 ASN 的存档：ASN + 时间（省年份）', () {
      const info = RecordInfo(
        id: 'AS13335-20261120-234712',
        at: '2026-11-20 23:47',
        isArchive: true,
      );
      expect(info.label, 'AS13335 · 11-20 23:47');
    });

    test('取不到 ASN 的存档：明确标「未知ASN」，不要假装成普通时间', () {
      const info = RecordInfo(
        id: 'unknown-20261120-234712',
        at: '2026-11-20 23:47',
        isArchive: true,
      );
      expect(info.label, '未知ASN · 11-20 23:47');
    });

    test('老存档（纯时间戳命名）：只显示时间', () {
      const info = RecordInfo(
        id: '20261120-234712',
        at: '2026-11-20 23:47',
        isArchive: true,
      );
      expect(info.label, '2026-11-20 23:47');
    });

    test('普通测试记录不是存档：不拼 ASN', () {
      const info = RecordInfo(
        id: '20261120-234712',
        at: '2026-11-20 23:47',
      );
      expect(info.label, '2026-11-20 23:47');
    });
  });

  group('渲染层不许再写回 info.at', () {
    test('本地测试页的选记录弹层：存档行必须用 info.label', () {
      final src = File('lib/ui/pages/test_page.dart').readAsStringSync();
      expect(src.contains('info.label'), isTrue,
          reason: '选记录弹层要用 info.label，否则存档只显示时间、丢掉 ASN');
      expect(
        RegExp(r"isArchive\s*\?\s*'\$\{info\.at\}").hasMatch(src),
        isFalse,
        reason: '存档分支不能再拼 info.at（就是这里漏掉了 ASN）',
      );
    });

    test('远程执行页的选数据弹层：标题同样用 info.label', () {
      final src = File('lib/ui/pages/remote_page.dart').readAsStringSync();
      expect(src.contains('info.label'), isTrue);
    });
  });
}
