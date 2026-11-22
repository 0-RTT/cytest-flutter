import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/bin.dart';
import 'data/censys_native.dart';
import 'data/censys_windows.dart';
import 'state/app_state.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState()..boot();
  runApp(
    ChangeNotifierProvider(
      create: (_) => state,
      child: const CytestApp(),
    ),
  );

  // 开发期探针：设了 CYTEST_PROBE_QUERY 就在启动后跑一次抓取，把结果写进
  // 系统临时目录的 cytest_probe.txt 然后退出。
  // Windows 的 GUI 程序没有控制台，只能落文件来验证抓取链路。
  //
  // CYTEST_PROBE_PROXYLINE=1 时走**和界面完全一样的编排**：
  // 起 xray（用设置里的第一条 vless）→ 拿端口 → 让 WebView2 走这个端口抓。
  final query = Platform.environment['CYTEST_PROBE_QUERY'];
  if (query != null && query.isNotEmpty) {
    _runFetchProbe(query, state);
  }
}

Future<void> _runFetchProbe(String query, AppState state) async {
  final log = File('${Directory.systemTemp.path}/cytest_probe.txt');
  await log.writeAsString('start ${DateTime.now().toIso8601String()}\nquery=$query\n');

  Future<void> trace(String stage) async {
    await log.writeAsString('$stage\n', mode: FileMode.append);
  }

  // 先记录引擎可用性：UI 里「获取不到数据」最常见的原因就是 xray/pipeline
  // 不存在，这条日志能一眼区分「引擎缺失」与「抓取失败」。
  for (final name in const ['xray', 'pipeline']) {
    try {
      final path = await Bins.path(name);
      await trace('bin:$name=$path');
    } on Object catch (e) {
      await trace('bin:$name MISSING ($e)');
    }
  }

  final useProxyLine = Platform.environment['CYTEST_PROBE_PROXYLINE'] == '1';
  final runLocal = Platform.environment['CYTEST_PROBE_LOCAL'] == '1';
  final logStorm = Platform.environment['CYTEST_PROBE_LOGSTORM'] == '1';

  try {
    if (logStorm) {
      // 压力测试：模拟三阶段运行时「每秒几十上百行日志 + 进度更新」的场景，
      // 用来量化 UI 通知风暴对帧率/CPU 的影响。
      _startFrameStats(log);
      // 等首帧画完再压：否则测到的是启动成本，不是「日志风暴下 UI 是否还会动」。
      await Future<void>.delayed(const Duration(seconds: 3));
      var notified = 0;
      void count() => notified++;
      state.addListener(count);
      final sw = Stopwatch()..start();
      for (var i = 1; i <= 800; i++) {
        state.pushLog('[延迟 $i/800] 104.16.0.$i:443 ${100 + i % 900}ms');
        if (i % 20 == 0) {
          state.progressCur = i;
          state.progressTotal = 800;
          state.progressStage = '延迟阶段';
          state.notifyProgress();
        }
        if (i % 8 == 0) await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      state.flushNotifications();
      sw.stop();
      state.removeListener(count);
      await trace('storm:done 耗时=${sw.elapsedMilliseconds}ms logs=${state.logs.length} 通知次数=$notified');
      return;
    }
    if (runLocal) {
      // 与界面「本地测试」按钮同一个入口：写 input/config → 起 pipeline.exe → 读 CSV。
      final targetsFile = Platform.environment['CYTEST_PROBE_TARGETS'];
      final input = (targetsFile != null && File(targetsFile).existsSync())
          ? File(targetsFile).readAsStringSync()
          : '104.16.0.1:443\n104.16.0.2:443';
      await trace('local:start targets=${input.split('\n').where((l) => l.trim().isNotEmpty).length}');
      _startFrameStats(log);
      final sw = Stopwatch()..start();
      final ok = await state.runLocal(mode: 'latency', input: input);
      sw.stop();
      await trace('local:done ok=$ok rows=${state.rows.length} 耗时=${sw.elapsedMilliseconds}ms');
      for (final row in state.rows.take(3)) {
        await trace('row ${row['IP']}:${row['Port']} '
            'latency=${row['Latency (ms)']} reason=${row['Reason']}');
      }
      await trace('logs=${state.logs.length}');
      return;
    }

    if (!useProxyLine) {
      final body = await fetchCensysSearchWindows(
        query: query,
        timeout: const Duration(seconds: 30),
        proxyServer: Platform.environment['CYTEST_PROBE_PROXY'],
        trace: (s) => unawaited(trace(s)),
      );
      final head = body.substring(0, body.length > 200 ? 200 : body.length);
      await log.writeAsString('OK len=${body.length}\nhead=$head\n',
          mode: FileMode.append);
      return;
    }

    // ---- 与界面同一条路径：线路 → xray → 抓取 ----
    await trace('settings.vlessLinks=${state.settings.vlessLinks.length}');
    if (state.settings.vlessLinks.isEmpty) {
      await trace('ERR 设置里没有 vless 链接');
      return;
    }
    await trace('xray:start');
    await state.startProxyLine(null); // null = 链接原样（不替换 proxyip）
    final port = state.xray.port;
    await trace('xray:ready port=$port running=${state.xray.running}');

    final body = await fetchCensysSearch(
      query: query,
      proxyPort: port,
      timeout: const Duration(seconds: 40),
    );
    // 走完界面在抓取成功后的那一步：落存档。这一步跑通，界面里就只剩 setState。
    await state.saveArchive(body);
    await trace('archive:saved');
    final head = body.substring(0, body.length > 200 ? 200 : body.length);
    await log.writeAsString('OK len=${body.length} port=$port\nhead=$head\n',
        mode: FileMode.append);
  } on Object catch (e) {
    await log.writeAsString('ERR $e\n', mode: FileMode.append);
  } finally {
    final sink = frameStatsSink;
    if (sink != null) {
      await sink();
      frameStatsSink = null;
    }
    try {
      await state.stopProxyLine();
    } on Object catch (_) {}
    exit(0);
  }
}

/// 帧耗时统计（用于评估「动画是否流畅」）：设 CYTEST_PROBE_FRAMES=1 时启用，
/// 统计 build / raster 的 p50/p95 与「掉帧」数（>16.7ms 记为掉一帧）。
void _startFrameStats(File log) {
  if (Platform.environment['CYTEST_PROBE_FRAMES'] != '1') return;
  final build = <int>[];
  final raster = <int>[];
  SchedulerBinding.instance.addTimingsCallback((frames) {
    for (final f in frames) {
      build.add(f.buildDuration.inMicroseconds);
      raster.add(f.rasterDuration.inMicroseconds);
    }
  });
  // 退出前由探针调用 frameStatsSink 落盘（exit(0) 前必须 prompt 一次）。
  frameStatsSink = (() async {
    int pct(List<int> v, double p) {
      if (v.isEmpty) return 0;
      final sorted = [...v]..sort();
      final idx = ((sorted.length - 1) * p).round();
      return sorted[idx];
    }

    String fmt(int us) => '${(us / 1000).toStringAsFixed(1)}ms';
    final jank = build.where((d) => d > 16700).length;
    await log.writeAsString(
      'frames=${build.length} '
      'build p50=${fmt(pct(build, 0.5))} p95=${fmt(pct(build, 0.95))} max=${fmt(pct(build, 1))} | '
      'raster p50=${fmt(pct(raster, 0.5))} p95=${fmt(pct(raster, 0.95))} max=${fmt(pct(raster, 1))} | '
      'jank=$jank\n',
      mode: FileMode.append,
    );
  });
}

/// 由 [_startFrameStats] 设置；探针在退出前调用一次。
Future<void> Function()? frameStatsSink;
