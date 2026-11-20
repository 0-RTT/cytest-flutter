import 'dart:convert';
import 'dart:io';

import '../core/paths.dart';
import '../core/settings.dart';
import 'censys_json.dart';
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
    this.isRemote = false,
  });

  /// 远程执行（服务器上跑）的结果，与本地 runs 同结构、不同目录。
  final bool isRemote;

  /// 存档文件名里的 ASN（`AS13335-20261120-223012` → `AS13335`）。
  ///
  /// 老存档名是纯时间戳、或抓取时取不到 ASN（写成 unknown），这里都返回 null。
  String? get asn {
    if (!isArchive) return null;
    final head = id.split('-').first;
    return head.startsWith('AS') ? head : null;
  }

  /// 给人看的名字：存档带 ASN 时 `AS13335 · 2026-11-20 22:30`；
  /// 抓取时取不到 ASN（文件名 `unknown-...`）显示「未知ASN」——
  /// 这样能区分「命名没生效」与「这条数据本来就没有 ASN 字段」。
  String get label {
    // 存档行右侧还有「导出 / 删除」两个图标，标题必须够短才不会被压成省略号，
    // 所以这里省掉年份（同一年内的记录看时间就够）。
    final short = at.length >= 16 ? at.substring(5) : at;
    if (asn != null) return '$asn · $short';
    if (id.startsWith('unknown-')) return '未知ASN · $short';
    return at;
  }
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
      // 单条记录坏掉（半截 CSV / 编码异常）只跳过这一条，
      // 不能让一次 IO 异常把整个列表打成「一直转圈」。
      try {
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
      } catch (_) {
        continue;
      }
    }
    out.sort((a, b) => b.id.compareTo(a.id));
    return out;
  }

  /// 远程执行结果列表（结构与 [listRuns] 一致，目录不同）。
  static Future<List<RecordInfo>> listRemote() async {
    final dir = await Paths.remote();
    if (!await dir.exists()) return const [];
    final out = <RecordInfo>[];
    await for (final entity in dir.list()) {
      if (entity is! Directory) continue;
      final id = entity.path.split(Platform.pathSeparator).last;
      try {
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
          isRemote: true,
        ));
      } catch (_) {
        continue;
      }
    }
    out.sort((a, b) => b.id.compareTo(a.id));
    return out;
  }

  /// 删除一条远程执行记录（整目录）。
  static Future<void> deleteRemote(String id) async {
    final dir = await Paths.remote();
    final target = Directory('${dir.path}/$id');
    if (await target.exists()) await target.delete(recursive: true);
  }

  /// 直接读某条记录的 result.csv 原文（导出用；不重新序列化，保留引擎的列顺序）。
  static Future<String> readCsv(String id, {bool remote = false}) async {
    final dir = remote ? await Paths.remote() : await Paths.runs();
    final file = File('${dir.path}/$id/result.csv');
    if (!await file.exists()) throw Exception('这条记录没有 result.csv');
    return file.readAsString();
  }

  /// 存档列表。
  ///
  /// **只读文件头 [_archiveHeadBytes]，不再整份读入 + jsonDecode**：
  /// 一次 Censys 抓取的 JSON 可能有几十 MB，过去每个存档都全量解析，
  /// 打开「记录」页会把 UI 线程卡住几十秒，表现就是无限转圈。
  /// `total_hits` 在响应体开头几百字节内，读 16KB 足够。
  static const int _archiveHeadBytes = 16 * 1024;

  static Future<List<RecordInfo>> listArchives() async {
    final dir = await Paths.archive();
    if (!await dir.exists()) return const [];

    final out = <RecordInfo>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final stat = await entity.stat();
        final id = entity.path
            .split(Platform.pathSeparator)
            .last
            .replaceAll('.json', '');

        var hits = 0;
        final raf = await entity.open();
        try {
          final head = await raf.read(_archiveHeadBytes);
          final text = utf8.decode(head, allowMalformed: true);
          final m =
              RegExp(r'"total_hits"\s*:\s*(\d+)').firstMatch(text);
          if (m != null) hits = int.tryParse(m.group(1)!) ?? 0;
        } finally {
          await raf.close();
        }

        out.add(RecordInfo(
          id: id,
          at: _formatTimestamp(stat.modified),
          total: hits,
          bytes: stat.size,
          isArchive: true,
        ));
      } catch (_) {
        // 单个存档读不出来就跳过，不影响其它条目。
        continue;
      }
    }
    out.sort((a, b) => b.id.compareTo(a.id));
    return out;
  }

  static String _formatId(String id) {
    // 本地 runs：`20261120-234712`（15 字符）
    if (id.length == 15 && id[8] == '-') {
      return '${id.substring(0, 4)}-${id.substring(4, 6)}-${id.substring(6, 8)} '
          '${id.substring(9, 11)}:${id.substring(11, 13)}';
    }
    // 远程结果：`AS13335-20261120-234712-remote`（带 ASN 前缀与后缀）
    final m = RegExp(r'^(?:[A-Za-z0-9]+-)?(\d{8})-(\d{6})').firstMatch(id);
    if (m != null) {
      final d = m.group(1)!;
      final t = m.group(2)!;
      return '${d.substring(0, 4)}-${d.substring(4, 6)}-${d.substring(6, 8)} '
          '${t.substring(0, 2)}:${t.substring(2, 4)}';
    }
    return id;
  }

  static String _formatTimestamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  /// 存档文件名：`<ASN>-<yyyyMMdd-HHmmss>`，例如 `AS13335-20261120-223012.json`。
  ///
  /// 带 ASN 是为了「一眼看出这是哪个网段的数据」：同一批候选往往来自同一个
  /// 骨干（Cloudflare 13335 之类），光看时间戳根本分不出两份存档的差别。
  /// ASN 取命中里的**众数**（见 [dominantAsn]）；取不到就写 `unknown`，
  /// 绝不因为命名失败而丢数据。
  static Future<String> saveArchive(String body) async {
    if (body.length < 100) throw Exception('内容过短，不存档');
    final dir = await Paths.archive();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final asn = dominantAsn(body) ?? 'unknown';
    final id = '$asn-$stamp';
    final file = File('${dir.path}/$id.json');
    await file.writeAsString(body, flush: true);
    return file.path;
  }

  /// 存档导出成 data.txt 时的建议文件名：`AS13335-20261120-234712-data.txt`。
  static String dataTxtName(String archiveId) => '$archiveId-data.txt';

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
