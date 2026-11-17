import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/bin.dart';
import '../core/paths.dart';
import '../core/settings.dart';

/// 一次本地测试的产物。
class RunOutput {
  final Directory dir;
  final List<Map<String, String>> rows;

  const RunOutput(this.dir, this.rows);

  int get total => rows.length;
  int get usable => rows.where((r) => (r['Reason'] ?? '').isEmpty).length;
  double get fastest => rows
      .where((r) => (r['Reason'] ?? '').isEmpty)
      .map((r) => double.tryParse(r['Speed (MiB/s)'] ?? '') ?? 0)
      .fold<double>(0, (a, b) => b > a ? b : a);
}

/// 三阶段引擎的 Dart 侧封装：调用打包的 Go 二进制，流式回传日志。
class Pipeline {
  Pipeline._();

  /// [mode] 为 full（Censys JSON，跑三阶段）或 speed（ip:port 列表，只测速）。
  static Future<RunOutput> run({
    required String mode,
    required String input,
    required AppSettings settings,
    required void Function(String line) onLine,
    void Function(int current, int total, String stage)? onProgress,
  }) async {
    final exe = await Bins.ensure('pipeline');
    final runsRoot = await Paths.runs();
    final stamp = _stamp();
    final runDir = Directory('${runsRoot.path}/$stamp');
    await runDir.create(recursive: true);

    final inputFile = File('${runDir.path}/input.txt');
    final cfgFile = File('${runDir.path}/config.json');
    final resultFile = File('${runDir.path}/result.csv');
    final consoleFile = File('${runDir.path}/console.log');

    await inputFile.writeAsString(input, flush: true);
    await cfgFile.writeAsString(_configJson(settings), flush: true);

    final args = <String>[
      '-config', cfgFile.path,
      '-result', resultFile.path,
      if (mode == 'speed') ...['-only-speed', '-targets', inputFile.path]
      else ...['-data', inputFile.path],
    ];

    final proc = await Process.start(exe.path, args, workingDirectory: runDir.path);
    final logSink = consoleFile.openWrite();

    final progressRe = RegExp(r'\[[^\]]*?(\d+)/(\d+)\]');
    var stage = '';

    Future<void> pump(Stream<List<int>> stream) async {
      await for (final chunk in stream.transform(utf8.decoder).transform(const LineSplitter())) {
        onLine(chunk);
        logSink.writeln(chunk);
        if (chunk.contains('阶段') && chunk.runes.length < 80) {
          stage = chunk.trim();
        }
        final m = progressRe.firstMatch(chunk);
        if (m != null) {
          final cur = int.tryParse(m.group(1)!) ?? 0;
          final tot = int.tryParse(m.group(2)!) ?? 0;
          if (tot > 0 && cur <= tot) {
            onProgress?.call(cur, tot, stage);
          }
        }
      }
    }

    final outDone = pump(proc.stdout);
    final errDone = pump(proc.stderr);
    final code = await proc.exitCode;
    await Future.wait([outDone, errDone]);
    await logSink.flush();
    await logSink.close();

    if (code != 0) {
      // 仍尝试读结果：pipeline 可能在部分失败时也写了 csv
      final partial = await _readCsv(resultFile);
      if (partial.isEmpty) {
        throw Exception('pipeline 退出码 $code，且没有产出结果');
      }
      return RunOutput(runDir, partial);
    }

    final rows = await _readCsv(resultFile);
    return RunOutput(runDir, rows);
  }

  static String _stamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  static String _configJson(AppSettings s) => const JsonEncoder.withIndent('  ').convert({
        'TargetSHA1Hash': s.fingerprint,
        'MaxSha1Concurrency': s.sha1Concurrency,
        'speedTestURL': s.speedUrl,
        'dialTimeout': s.dialTimeout,
        'downloadTimeout': s.downloadTimeout,
        'maxLatencyConcurrency': s.latencyConcurrency,
        'maxSpeedConcurrency': s.speedConcurrency,
        'maxLatency': s.maxLatency,
        if (s.httpProxy.trim().isNotEmpty) 'httpProxy': s.httpProxy.trim(),
      });

  static Future<List<Map<String, String>>> _readCsv(File file) async {
    if (!await file.exists()) return const [];
    final text = await file.readAsString();
    return parseCsv(text);
  }

  /// 读回历史记录的结果。
  static Future<List<Map<String, String>>> readRunResult(String runId) async {
    final runsRoot = await Paths.runs();
    return _readCsv(File('${runsRoot.path}/$runId/result.csv'));
  }
}

/// 解析 pipeline 产出的 CSV（表头：IP, Port, Latency (ms), Speed (MiB/s), Reason）。
List<Map<String, String>> parseCsv(String text) {
  final rows = _splitCsv(text);
  if (rows.isEmpty) return const [];
  final header = rows.first;
  final out = <Map<String, String>>[];
  for (var i = 1; i < rows.length; i++) {
    final rec = rows[i];
    if (rec.isEmpty) continue;
    final map = <String, String>{};
    for (var c = 0; c < header.length; c++) {
      map[header[c]] = c < rec.length ? rec[c] : '';
    }
    out.add(map);
  }
  out.sort((a, b) {
    final x = double.tryParse(a['Speed (MiB/s)'] ?? '') ?? 0;
    final y = double.tryParse(b['Speed (MiB/s)'] ?? '') ?? 0;
    return y.compareTo(x);
  });
  return out;
}

/// 极简 CSV 解析，支持双引号包裹与转义引号。
List<List<String>> _splitCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(ch);
      }
      continue;
    }
    switch (ch) {
      case '"':
        inQuotes = true;
        break;
      case ',':
        row.add(field.toString());
        field.clear();
        break;
      case '\r':
        break;
      case '\n':
        row.add(field.toString());
        field.clear();
        if (row.any((e) => e.isNotEmpty)) rows.add(row);
        row = <String>[];
        break;
      default:
        field.write(ch);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    if (row.any((e) => e.isNotEmpty)) rows.add(row);
  }
  return rows;
}
