import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 统一的数据目录：应用私有目录下的 cytest/，与 Android 端 filesDir 语义一致。
class Paths {
  Paths._();

  static Directory? _root;

  static Future<Directory> root() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/cytest');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _root = dir;
    return dir;
  }

  static Future<Directory> runs() async =>
      _ensure('${(await root()).path}/runs');

  static Future<Directory> archive() async =>
      _ensure('${(await root()).path}/archive');

  static Future<Directory> xray() async =>
      _ensure('${(await root()).path}/xray');

  static Future<Directory> bin() async =>
      _ensure('${(await root()).path}/bin');

  static Future<Directory> _ensure(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
