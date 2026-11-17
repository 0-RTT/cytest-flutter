import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/bin.dart';
import '../core/paths.dart';
import '../core/settings.dart';
import '../data/history.dart';
import '../data/pipeline.dart';
import '../data/vless.dart';
import '../data/xray.dart';

/// 全局状态：设置、线路、测试运行、结果。与 Android 端 TestViewModel 的职责对齐。
class AppState extends ChangeNotifier {
  AppSettings settings = AppSettings();
  final XrayProc xray = XrayProc();

  List<Map<String, String>> rows = const [];
  Directory? lastRunDir;
  String? lastError;

  final List<String> logs = [];
  bool running = false;
  int progressCur = 0;
  int progressTotal = 0;
  String progressStage = '';

  bool booting = true;
  String binStatus = '';

  Future<void> boot() async {
    settings = await AppSettings.load();
    booting = false;
    notifyListeners();
    unawaited(_warmBinaries());
  }

  /// 预释放二进制，避免第一次测试时卡几秒。
  Future<void> _warmBinaries() async {
    try {
      await Bins.path('pipeline');
      binStatus = '引擎就绪';
    } catch (e) {
      binStatus = '引擎异常：$e';
    }
    notifyListeners();
  }

  Future<void> saveSettings() async {
    await settings.save();
    notifyListeners();
  }

  void pushLog(String line) {
    logs.add(line);
    if (logs.length > 2000) {
      logs.removeRange(0, logs.length - 2000);
    }
    notifyListeners();
  }

  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  Vless? get primaryLine {
    for (final link in settings.vlessLinks) {
      final v = Vless.tryParse(link);
      if (v != null) return v;
    }
    return null;
  }

  List<ProxyIp> get proxyPool => parseProxyCsv(settings.proxyIps.join('\n'));

  Future<void> startLine() async {
    final v = primaryLine;
    if (v == null) throw Exception('先在「线路与代理」填一条 vless 链接');
    final pool = proxyPool;
    await xray.start(v, proxy: pool.isEmpty ? null : pool.first);
    notifyListeners();
  }

  Future<void> stopLine() async {
    await xray.stop();
    notifyListeners();
  }

  /// 本地三阶段。返回是否成功。
  Future<bool> runLocal({required String mode, required String input}) async {
    if (running) throw Exception('上一次测试还在进行');
    if (input.trim().isEmpty) throw Exception('先粘贴候选数据');

    running = true;
    lastError = null;
    rows = const [];
    clearLogs();
    progressCur = 0;
    progressTotal = 0;
    progressStage = '';
    notifyListeners();

    try {
      final out = await Pipeline.run(
        mode: mode,
        input: input,
        settings: settings,
        onLine: pushLog,
        onProgress: (cur, total, stage) {
          progressCur = cur;
          progressTotal = total;
          progressStage = stage;
          notifyListeners();
        },
      );
      rows = out.rows;
      lastRunDir = out.dir;
      return true;
    } catch (e) {
      lastError = e.toString();
      pushLog('✗ $e');
      return false;
    } finally {
      running = false;
      notifyListeners();
    }
  }

  Future<void> cancel() async {
    // pipeline 进程由 Pipeline.run 内部持有；这里通过杀同名进程兜底
    try {
      await Process.run('pkill', ['-f', 'cytest/pipeline']);
    } catch (_) {}
  }

  List<(String, String)> get usableTargets {
    final out = <(String, String)>[];
    for (final r in rows) {
      if ((r['Reason'] ?? '').isNotEmpty) continue;
      final ip = r['IP'] ?? '';
      final port = r['Port'] ?? '';
      if (ip.isEmpty || port.isEmpty) continue;
      out.add((ip, port));
    }
    return out;
  }

  int get usableCount => usableTargets.length;

  double get fastestSpeed {
    var best = 0.0;
    for (final r in rows) {
      if ((r['Reason'] ?? '').isNotEmpty) continue;
      final v = double.tryParse(r['Speed (MiB/s)'] ?? '') ?? 0;
      if (v > best) best = v;
    }
    return best;
  }

  int get averageLatency {
    final lats = rows
        .where((r) => (r['Reason'] ?? '').isEmpty)
        .map((r) => int.tryParse(r['Latency (ms)'] ?? '') ?? 0)
        .where((v) => v > 0)
        .toList();
    if (lats.isEmpty) return 0;
    return lats.reduce((a, b) => a + b) ~/ lats.length;
  }

  Future<void> loadRun(String id) async {
    final loaded = await Pipeline.readRunResult(id);
    if (loaded.isEmpty) throw Exception('该记录没有结果');
    rows = loaded;
    notifyListeners();
  }

  Future<void> saveArchive(String body) async {
    try {
      await History.saveArchive(body);
    } catch (_) {
      // 存档失败不影响主流程
    }
  }
}
