import 'dart:convert';
import 'dart:io';

import '../core/paths.dart';
import '../core/settings.dart';
import 'pipeline.dart';

class RecordInfo {
  final String id;
  final String at;
  final int total;
  final int usable;
  final double fastest;
  final int bytes;
  final bool isArchive;

  const RecordInfo({
    required this.id,
    required this.at,
    this.total = 0,
    this.usable = 0,
    this.fastest = 0,
    this.bytes = 0,
    this.isArchive = false,
  });
}

/// 历史记录与存档，语义对齐桌面端 history.go。
class History {
  History._();

  static Future<List<RecordInfo>> listRuns() async {
    final dir = await Paths.runs();
    if (!await dir.exists()) return const [];

    final out = <RecordInfo>[];
    await for (final entity in dir.list()) {
      if (entity is! Directory) continue;
      final id = entity.path.split(Platform.pathSeparator).last;
      final csv = File('${entity.path}/result.csv');
      if (!await csv.exists()) continue;

      final rows = parseCsv(await csv.readAsString());
      if (rows.isEmpty) continue;

      var usable = 0;
      var fastest = 0.0;
      for (final r in rows) {
        if ((r['Reason'] ?? '').isNotEmpty) continue;
        usable++;
        final v = double.tryParse(r['Speed (MiB/s)'] ?? '') ?? 0;
        if (v > fastest) fastest = v;
      }
      out.add(RecordInfo(
        id: id,
        at: _formatId(id),
        total: rows.length,
        usable: usable,
        fastest: fastest,
      ));
    }
    out.sort((a, b) => b.id.compareTo(a.id));
    return out;
  }

  static Future<List<RecordInfo>> listArchives() async {
    final dir = await Paths.archive();
    if (!await dir.exists()) return const [];

    final out = <RecordInfo>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final stat = await entity.stat();
      final id = entity.path.split(Platform.pathSeparator).last.replaceAll('.json', '');

      var hits = 0;
      try {
        final raw = await entity.readAsString();
        final obj = jsonDecode(raw) as Map<String, dynamic>;
        final results = obj['results'] as Map<String, dynamic>?;
        hits = (results?['total_hits'] as num?)?.toInt() ?? 0;
      } catch (_) {}

      out.add(RecordInfo(
        id: id,
        at: _formatTimestamp(stat.modified),
        total: hits,
        bytes: stat.size,
        isArchive: true,
      ));
    }
    out.sort((a, b) => b.id.compareTo(a.id));
    return out;
  }

  static String _formatId(String id) {
    if (id.length == 15 && id[8] == '-') {
      return '${id.substring(0, 4)}-${id.substring(4, 6)}-${id.substring(6, 8)} '
          '${id.substring(9, 11)}:${id.substring(11, 13)}';
    }
    return id;
  }

  static String _formatTimestamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  static Future<String> saveArchive(String body) async {
    if (body.length < 100) throw Exception('内容过短，不存档');
    final dir = await Paths.archive();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final id = '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final file = File('${dir.path}/$id.json');
    await file.writeAsString(body, flush: true);
    return file.path;
  }

  static Future<String> readArchive(String id) async {
    final dir = await Paths.archive();
    final file = File('${dir.path}/$id.json');
    if (!await file.exists()) throw Exception('存档不存在：$id');
    return file.readAsString();
  }

  static Future<void> deleteRun(String id) async {
    _checkId(id);
    final dir = await Paths.runs();
    final target = Directory('${dir.path}/$id');
    if (!await target.exists()) throw Exception('记录不存在：$id');
    await target.delete(recursive: true);
  }

  static Future<void> deleteArchive(String id) async {
    _checkId(id);
    final dir = await Paths.archive();
    final target = File('${dir.path}/$id.json');
    if (!await target.exists()) throw Exception('存档不存在：$id');
    await target.delete();
  }

  static void _checkId(String id) {
    if (id.isEmpty || id.contains('..') || id.contains('/') || id.contains(r'\')) {
      throw Exception('非法的记录 ID');
    }
  }

  /// 导出到应用文档目录（Android 上为 /data/user/0/<pkg>/files，可通过分享导出）。
  static Future<File> writeExport(String name, String content,
      {required Directory target}) async {
    final file = File('${target.path}/$name');
    await file.writeAsString(content, flush: true);
    return file;
  }

  static Future<String> exportBackup(AppSettings settings, Directory target) async {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name = 'cytest-backup-${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.json';
    final file = await writeExport(name, const JsonEncoder.withIndent('  ').convert(settings.toJson()),
        target: target);
    return file.path;
  }

  static AppSettings importBackup(String raw) {
    final text = raw.trim();
    if (text.isEmpty) throw Exception('备份内容为空');
    final json = jsonDecode(text) as Map<String, dynamic>;
    return AppSettings.fromJson(json);
  }
}
