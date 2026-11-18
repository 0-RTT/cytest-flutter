import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/bin.dart';
import '../core/idna.dart';
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

  /// 运行模式与 Go 侧 flag 的映射：
  /// - `latency` → `-only-latency -targets`（只做延迟）；
  /// - `speed`   → `-only-speed -targets`（只做速度）；
  /// - `both`    → `-targets`（延迟 + 速度）；
  /// - `full`    → `-data`（Censys JSON：指纹筛选 + 延迟 + 速度）。
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
      ..._modeArgs(mode, inputFile.path),
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
        // 走到这里 = 引擎在写盘前就退出了：三种模式「零可用结果」也会落 CSV
        // （见 engine/pipeline.go 的 reportLatencyResults / reportSpeedResults，
        // 以及 -targets 延迟阶段全挂时补写的 writeLatencyFailureCSV），所以全失败
        // 不会走到本分支。常见成因：-data 模式阶段1 指纹筛选无命中（合法结局，
        // exit 1，一个字节都不写）、参数或清单错误（exit 2）、配置读取/解析失败、
        // panic、或被强杀。文案仍要说人话，退出码留在括号里便于对上 Go 侧日志。
        throw Exception('没有测出可用结果（引擎退出码 $code）');
      }
      return RunOutput(runDir, partial);
    }

    final rows = await _readCsv(resultFile);
    return RunOutput(runDir, rows);
  }

  /// 把运行模式翻译成 pipeline 的命令行参数（不含 `-config` / `-result`）。
  ///
  /// 抽成纯函数便于单测；未识别的模式按 `full` 处理，保持旧行为。
  static List<String> _modeArgs(String mode, String inputPath) {
    switch (mode) {
      case 'latency':
        return <String>['-only-latency', '-targets', inputPath];
      case 'speed':
        return <String>['-only-speed', '-targets', inputPath];
      case 'both':
        return <String>['-targets', inputPath];
      default:
        return <String>['-data', inputPath];
    }
  }

  static String _stamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  /// 生成交给 Go 引擎的 config.json。
  ///
  /// **绝不写 `httpProxy`**：这里与 Kotlin 版严格对齐 ——
  /// 原版 `LocalSpeedProtocol.configJson()` 的字段集只有
  /// `speedTestURL / dialTimeout / downloadTimeout / maxSpeedConcurrency /
  /// maxLatency / maxLatencyConcurrency / MaxSha1Concurrency`，
  /// `LocalSpeedRunner` 的启动参数也只有 `-only-speed -targets -config -result`，
  /// 全工程 grep `httpProxy` 零命中。也就是说**原版的优选 IP 测速永远是直连**。
  ///
  /// 曾经的 Flutter 版把设置页一个「测速代理」值塞进 httpProxy，
  /// 结果用户填了一个非 HTTP 代理的地址（节点端口 / CDN 入口）后，
  /// 553 条候选全部被 `dialTunnelViaProxy` 判成「代理隧道失败」——
  /// 表面是「所有节点都挂了」，实际是测速流量被一条假隧道全吃掉了。
  /// 引擎侧的 httpProxy 能力保留（远程执行 / CLI 仍可用），但 App 不传。
  static String _configJson(AppSettings s) => buildEngineConfig(s);

  /// 生成交给 Go 引擎的 config.json 文本（纯函数，可直接单测）。
  ///
  /// 与 [_configJson] 是同一份实现：`_configJson` 只保留旧名转调，避免
  /// 已有回归测试（test/speed_direct_test.dart、test/pipeline_mode_test.dart）
  /// 依赖的符号消失。公开还有一个原因 —— 让
  /// test/speed_url_idn_test.dart 能断言**真实产出**，而不是「源码里含有某个
  /// 字符串」这种抓不出真 Bug 的弱断言。
  ///
  /// **全 App 只有这一处组装 config.json**：远端执行 `RemoteRunner` 也转调它。
  /// 曾经两处各抄一份、都直接写入 `s.speedUrl`，于是本地与远端两条路径
  /// 一起被 IDN 主机名打成「全部失败」（见 [engineSpeedUrl]）。
  static String buildEngineConfig(AppSettings s) =>
      const JsonEncoder.withIndent('  ').convert({
        'TargetSHA1Hash': s.fingerprint,
        'MaxSha1Concurrency': s.sha1Concurrency,
        'speedTestURL': engineSpeedUrl(s.speedUrl),
        'dialTimeout': s.dialTimeout,
        'downloadTimeout': s.downloadTimeout,
        'maxLatencyConcurrency': s.latencyConcurrency,
        'maxSpeedConcurrency': s.speedConcurrency,
        'maxLatency': s.maxLatency,
      });

  /// 把设置里的测速地址归一成「主机名一定全 ASCII（punycode）」的形式。
  ///
  /// 凡是把测速地址交给引擎的地方都必须过它（本地三阶段 / 远端执行）。
  ///
  /// **为什么必须归一（本 Bug 的根因）**：Go 引擎的 `ClientPool.NewClient`
  /// 构造 `tls.Config{}` 时**不设 ServerName**，`http.Transport` 于是拿 URL 里的
  /// 原始主机名当 SNI 与 Host 头。默认测速地址 `https://е.eu.org/300.zip` 里的
  /// `е` 是**西里尔字母 U+0435**（不是拉丁 e），SNI 就成了非 ASCII 的
  /// `е.eu.org` —— Cloudflare 边缘不认识这种 SNI，直接回
  /// `TLS alert 40 (handshake failure)`，连证书都读不回来。后果不是「速度测错」，
  /// 而是**每一条候选都在握手阶段被否掉**，用户看到「本地测试全部失败」，
  /// 从而误判「所有 CDN 都挂了」。
  ///
  /// 实测对照（同一个边缘 IP 104.21.17.194:443）：
  /// - SNI=`xn--e1a.eu.org` → 握手成功（`subject=CN=xn--e1a.eu.org`），
  ///   下载返回 HTTP 206 / 262144 字节；
  /// - SNI=`е.eu.org` → `handshake failure (alert 40)`，只读回 7 字节。
  /// 即：候选 IP 与测速文件本身都没问题，唯一的问题是 SNI 用了非 punycode 主机名。
  ///
  /// **为什么改在「交给引擎的边界」而不是改 `Defaults.speedUrl`**：
  /// Kotlin 原版（`Defaults.kt:17`）保留的也是 Unicode 默认值，只在
  /// `LocalSpeedProtocolTest.kt:168` 断言的 `describe()` 输出里归一成
  /// `xn--e1a.eu.org:443/300.zip` —— 归一发生在**使用侧**。只把默认值改成
  /// `xn--` 字面量只能救默认值，用户手填任何 IDN 域名仍然全挂。
  ///
  /// **失败语义**：`probeUri` 抛的异常一律转成**人话 [Exception]**，让
  /// `AppState.runLocal` / `RemoteRunner` 的 catch 把它显示在日志里。
  /// **绝不静默退回原串** —— 退回去就等于又变成「引擎退出码 N、所有候选都失败」
  /// 这种用户完全看不懂的现象（host 名不对时改设置才是正解，不是重试）。
  ///
  /// 协议 / 端口 / path / query 全部保留：只替换 host（`Uri.replace` 语义）。
  static String engineSpeedUrl(String raw) {
    try {
      return probeUri(raw).toString();
    } on UnsupportedIdnException catch (e) {
      throw Exception(
        '测速地址的域名含不支持的字符（${e.message}），无法转成 punycode：$raw\n'
        '请改成一个纯 ASCII 的直链，或把域名换成 xn-- 形式的 punycode 后重试',
      );
    } on FormatException catch (e) {
      throw Exception(
        '测速地址不可用：${e.message}\n'
        '请在「线路与代理 → 测速地址」填一个 http(s) 直链',
      );
    }
  }

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
