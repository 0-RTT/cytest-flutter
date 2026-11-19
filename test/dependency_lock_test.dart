import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 运行时依赖的「不可退让」约束。
///
/// 2026-11-19 事故：CI 用 `flutter pub upgrade` 追最新，把
/// `path_provider_android` 拉到 2.3.x、`shared_preferences_android` 拉到 2.5.x
/// —— 这两个版本把实现换成了 JNI 直连，在 release 包真机上直接抛：
///   Exception in Java: java.lang.ClassNotFoundException:
///   Didn't find class "Landroid/content/Context;"
/// 后果是 `getApplicationSupportDirectory()` 失败 → 记录页永远转圈。
/// analyze / unit test 都覆盖不到这类「只在真机炸」的问题，只能在依赖层面钉死。
void main() {
  late String lock;

  setUpAll(() {
    lock = File('pubspec.lock').readAsStringSync();
  });

  String versionOf(String name) {
    final m = RegExp(
      '^  $name:\\n(?:.*\\n)*?    version: "([^"]+)"',
      multiLine: true,
    ).firstMatch(lock);
    return m?.group(1) ?? '';
  }

  test('path_provider_android 停在 JNI 迁移前的 2.2.x', () {
    final v = versionOf('path_provider_android');
    expect(v, isNotEmpty, reason: 'pubspec.lock 里找不到该依赖');
    expect(v, startsWith('2.2.'),
        reason: '2.3.0 起改为 JNI 实现，真机必炸；实际解析到 $v');
  });

  test('shared_preferences_android 停在 JNI 迁移前的 2.4.x', () {
    final v = versionOf('shared_preferences_android');
    expect(v, isNotEmpty, reason: 'pubspec.lock 里找不到该依赖');
    expect(v, startsWith('2.4.'),
        reason: '2.5.0 起改为 JNI 实现；实际解析到 $v');
  });

  test('依赖树里不允许出现 jni / jni_flutter / jni_util', () {
    for (final pkg in ['jni', 'jni_flutter', 'jni_util']) {
      final has = RegExp('^  $pkg:', multiLine: true).hasMatch(lock);
      expect(has, isFalse,
          reason: '$pkg 会被带进 APK；说明有插件又迁到了 JNI 实现，'
              '需要先在真机验证「记录页能列出历史」再放开');
    }
  });
}
