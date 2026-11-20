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

  /// 远程执行结果（`cytest/remote/<id>/`，结构与 runs 一致：input.txt + result.csv）。
  ///
  /// 单独一个目录：来源不同（服务器上跑出来的），记录页要单独分组，
  /// 混进 runs 会让人分不清是本地还是远端测的。
  static Future<Directory> remote() async =>
      _ensure('${(await root()).path}/remote');

  static Future<Directory> xray() async =>
      _ensure('${(await root()).path}/xray');

  static Future<Directory> bin() async => _ensure('${(await root()).path}/bin');

  /// 链路测速历史（`cytest/linktest/<ts>.json`，只保留最近 20 个）。
  ///
  /// 与 [runs] 分开：`runs` 是三阶段漏斗的运行记录，两者生命周期与
  /// 保留策略不同，混在一起 prune 会互相删。
  static Future<Directory> linktest() async =>
      _ensure('${(await root()).path}/linktest');

  static Future<Directory> _ensure(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
