import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/bin.dart';
import '../core/paths.dart';
import '../core/settings.dart';
import 'xray.dart' show terminateProcess;

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

/// 三阶段运行的取消令牌：持有 [Process] 句柄，取消时走 sigterm → sigkill。
///
/// 为什么必须有它：旧实现是「按进程名匹配去杀」（`Process.run` 跑一条 name-match
/// 命令），而真实可执行文件是 `nativeLibraryDir/libpipeline.so` —— 名字匹配不到
/// 这个路径，**取消是空操作**，只是给用户一个「已取消」的错觉（设计 §2.3）。
/// 只有握着 `Process` 句柄去 kill 才是真的。
class PipelineCancelToken {
  Process? _proc;
  bool _cancelled = false;

  /// 是否已经请求取消。
  bool get cancelled => _cancelled;

  /// 进程是否还挂着（诊断用）。
  bool get attached => _proc != null;

  /// 由 [Pipeline.run] 在起进程后调用。若此前已取消，立刻终止。
  void attach(Process proc) {
    _proc = proc;
    if (_cancelled) {
      unawaited(terminateProcess(proc));
    }
  }

  /// 进程结束后解绑，避免持有已死句柄。
  void detach() {
    _proc = null;
  }

  /// 取消：置位 + 终止进程（幂等；未起进程时只置位，起进程时会立刻被杀）。
  Future<void> cancel() async {
    _cancelled = true;
    final proc = _proc;
    if (proc == null) return;
    _proc = null;
    await terminateProcess(proc);
  }
}

/// 三阶段引擎的 Dart 侧封装：调用打包的 Go 二进制，流式回传日志。
class Pipeline {
  Pipeline._();

  /// [mode] 为 full（Censys JSON，跑三阶段）或 speed（ip:port 列表，只测速）。
  ///
  /// [token] 用于取消：调用方 `await token.cancel()` 后本方法会在
  /// `proc.exitCode` 处自然返回（进程已死），无需额外中断逻辑。
  static Future<RunOutput> run({
    required String mode,
    required String input,
    required AppSettings settings,
    required void Function(String line) onLine,
    void Function(int current, int total, String stage)? onProgress,
    PipelineCancelToken? token,
  }) async {
    final exePath = await Bins.path('pipeline');
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
      '-config',
      cfgFile.path,
      '-result',
      resultFile.path,
      if (mode == 'speed') ...[
        '-only-speed',
        '-targets',
        inputFile.path
      ] else ...[
        '-data',
        inputFile.path
      ],
    ];

    final proc =
        await Process.start(exePath, args, workingDirectory: runDir.path);
    // 先把句柄交给令牌再读输出：否则「刚起进程就被取消」的窗口里会漏杀
    token?.attach(proc);
    final logSink = consoleFile.openWrite();

    final progressRe = RegExp(r'\[[^\]]*?(\d+)/(\d+)\]');
    var stage = '';

    Future<void> pump(Stream<List<int>> stream) async {
      await for (final chunk
          in stream.transform(utf8.decoder).transform(const LineSplitter())) {
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
    token?.detach();
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

  static String _configJson(AppSettings s) =>
      const JsonEncoder.withIndent('  ').convert({
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

/// 测速结果 CSV 的一行（原版 Kotlin `TestResult` 的最小字段集）。
///
/// 这个类型存在的意义：**proxyip 文件就是测速结果 CSV**（原版
/// `ProxyIpRepository.parseCsv` 直接委托 `SpeedResultCsv.parse`），
/// 所以两处必须共用同一套解析规则，不能各写一份。
class SpeedCsvRow {
  const SpeedCsvRow({
    required this.ip,
    required this.port,
    this.latencyMs = -1,
    this.speedMib = 0,
    this.reason = '',
  });

  final String ip;
  final int port;
  final int latencyMs;
  final double speedMib;
  final String reason;

  /// 与原版 `TestResult.key` 一致的唯一键。
  String get key => '$ip:$port';
}

/// 解析测速结果 CSV（也用作 proxyip 文件格式）。
///
/// 规则与原版 `CsvRows.split` + `SpeedResultCsv.parse` 对齐：
/// - UTF-8 BOM、CRLF/CR、双引号与 `""` 转义；
/// - 表头可有可无（首行首列是 `IP` 就当表头跳过）；
/// - `#` 开头的注释行、空行跳过；
/// - 至少 2 列（IP, Port），端口必须在 1..65535；
/// - 任何非法行**跳过而不是抛异常**（用户粘来的列表常混坏行）。
List<SpeedCsvRow> parseSpeedCsvRows(String text) {
  final rows = _splitCsv(text.replaceFirst('\uFEFF', ''));
  if (rows.isEmpty) return const [];

  var start = 0;
  if (_looksLikeIpHeader(rows.first)) start = 1;

  final out = <SpeedCsvRow>[];
  for (var i = start; i < rows.length; i++) {
    final cells = rows[i];
    if (cells.isEmpty) continue;
    if (cells.first.trim().startsWith('#')) continue;
    if (cells.length < 2) continue;

    final ip = cells[0].trim();
    if (ip.isEmpty || ip.contains(RegExp(r'\s'))) continue;
    final port = int.tryParse(cells[1].trim());
    if (port == null || port < 1 || port > 65535) continue;

    out.add(SpeedCsvRow(
      ip: ip,
      port: port,
      latencyMs: cells.length > 2 ? (int.tryParse(cells[2].trim()) ?? -1) : -1,
      speedMib: cells.length > 3 ? (double.tryParse(cells[3].trim()) ?? 0) : 0,
      reason: cells.length > 4 ? cells[4].trim() : '',
    ));
  }
  return out;
}

/// 把行写成测速结果 CSV（表头与列顺序对齐原版 `SpeedResultCsv` 的读取口径）。
///
/// [withReason] 为真时多写 Reason 列（三阶段结果用），proxyip 落盘用 4 列。
String toSpeedCsvText(List<SpeedCsvRow> rows, {bool withReason = false}) {
  final buffer = StringBuffer(
    withReason
        ? 'IP,Port,Latency (ms),Speed (MiB/s),Reason\n'
        : 'IP,Port,Latency (ms),Speed (MiB/s)\n',
  );
  for (final row in rows) {
    buffer
      ..write(row.ip)
      ..write(',')
      ..write(row.port)
      ..write(',')
      ..write(row.latencyMs)
      ..write(',')
      ..write(row.speedMib.toStringAsFixed(2));
    if (withReason)
      buffer
        ..write(',')
        ..write(row.reason);
    buffer.write('\n');
  }
  return buffer.toString();
}

bool _looksLikeIpHeader(List<String> row) {
  final first = row.isEmpty ? '' : row.first.trim().toLowerCase();
  return first == 'ip';
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
