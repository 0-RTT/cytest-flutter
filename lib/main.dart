import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'data/censys_windows.dart';
import 'state/app_state.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState()..boot(),
      child: const CytestApp(),
    ),
  );

  // 开发期探针：设了 CYTEST_PROBE_QUERY 就在启动后跑一次抓取，把结果写进
  // 系统临时目录的 cytest_probe.txt 然后退出。
  // Windows 的 GUI 程序没有控制台，只能落文件来验证抓取链路。
  final query = Platform.environment['CYTEST_PROBE_QUERY'];
  if (query != null && query.isNotEmpty) {
    _runFetchProbe(query);
  }
}

Future<void> _runFetchProbe(String query) async {
  final log = File('${Directory.systemTemp.path}/cytest_probe.txt');
  await log.writeAsString('start ${DateTime.now().toIso8601String()}\nquery=$query\n');

  Future<void> trace(String stage) async {
    await log.writeAsString('$stage\n', mode: FileMode.append);
  }

  try {
    final body = await fetchCensysSearchWindows(
      query: query,
      timeout: const Duration(seconds: 30),
      proxyServer: Platform.environment['CYTEST_PROBE_PROXY'],
      trace: (s) => unawaited(trace(s)),
    );
    final head = body.substring(0, body.length > 200 ? 200 : body.length);
    await log.writeAsString(
      'OK len=${body.length}\nhead=$head\n',
      mode: FileMode.append,
    );
  } on Object catch (e) {
    await log.writeAsString('ERR $e\n', mode: FileMode.append);
  } finally {
    exit(0);
  }
}
