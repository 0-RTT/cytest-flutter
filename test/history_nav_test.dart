import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 记录页的「测试历史」点进去必须看结果，而不是重新跑测试。
/// 这是一个接线错误：loadRun 已经把 rows 载入了，再跳 TestPage 会让用户
/// 误以为要重跑，且看不到刚载入的结果。用源码断言钉住，避免回归。
void main() {
  test('测试历史载入后跳结果页，存档仍跳本地测试页', () {
    final src = File('lib/ui/pages/history_page.dart').readAsStringSync();
    final openRun = src.substring(
      src.indexOf('Future<void> _openRun'),
      src.indexOf('Future<void> _openArchive'),
    );
    final openArchive = src.substring(
      src.indexOf('Future<void> _openArchive'),
    );

    expect(openRun, contains('const ResultPage()'));
    expect(openRun, isNot(contains('TestPage(')));
    // 存档是 Censys JSON，要拿去跑三阶段，进 TestPage 才对
    expect(openArchive, contains('TestPage(initialInput: body)'));
  });
}
