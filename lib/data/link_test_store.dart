import 'dart:convert';
import 'dart:io';

import '../core/paths.dart';
import 'link_test.dart';

/// 测速历史落盘：`cytest/linktest/<createdAt>.json`，只保留最近 [maxKeep] 个。
///
/// 为什么只写不读 UI：本次范围「做写入，不做浏览页」（设计 §1 #17）。
/// 落盘的价值是「测完刷新就丢」变成「还能捞回来」，浏览页另行迭代。
class LinkTestStore {
  LinkTestStore({this.maxKeep = 20, Directory? dir}) : _dirOverride = dir;

  /// 保留的历史条数上限。
  final int maxKeep;

  /// 注入目录（单测用临时目录，避免污染真实数据目录）。
  final Directory? _dirOverride;

  Future<Directory> _dir() async => _dirOverride ?? await Paths.linktest();

  /// 写一次运行。返回写出的文件（便于测试与日志）。
  ///
  /// 写完立刻 prune：历史文件是「按时间戳命名」的，越晚写越多，
  /// 放在写完时裁剪可以保证磁盘占用始终有界（T03 验收 5）。
  Future<File> save(LinkTestRun run) async {
    final dir = await _dir();
    final file = File('${dir.path}/${run.id}.json');
    await file.writeAsString(jsonEncode(run.toJson()), flush: true);
    await prune();
    return file;
  }

  /// 读全部历史（按文件名倒序 = 最新在前）。坏文件跳过，不让一条脏数据毁掉列表。
  Future<List<LinkTestRun>> list() async {
    final files = await _files();
    final runs = <LinkTestRun>[];
    for (final file in files) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) {
          runs.add(LinkTestRun.fromJson(decoded));
        }
      } on Object {
        // 半截文件（写入时被杀进程）等：跳过
      }
    }
    return runs;
  }

  /// 裁剪到 [maxKeep] 个（最新的保留）。
  Future<void> prune() async {
    final files = await _files();
    for (var i = maxKeep; i < files.length; i++) {
      try {
        await files[i].delete();
      } on Object {
        // 删不掉不影响主流程，下轮还会重试
      }
    }
  }

  /// 目录里的历史文件，按文件名**倒序**（时间戳越大越新）。
  Future<List<File>> _files() async {
    final dir = await _dir();
    if (!await dir.exists()) return const <File>[];
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        files.add(entity);
      }
    }
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }
}
