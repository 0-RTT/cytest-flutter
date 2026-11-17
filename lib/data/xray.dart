import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/bin.dart';
import '../core/paths.dart';
import 'vless.dart';

/// 本地空闲端口探测。
Future<int> freePort() async {
  for (var p = 20000; p < 20200; p++) {
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, p);
      await s.close();
      return p;
    } catch (_) {
      continue;
    }
  }
  return 20000;
}

Future<bool> waitPort(int port, {Duration timeout = const Duration(seconds: 8)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    try {
      final s = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(milliseconds: 300));
      await s.close();
      return true;
    } catch (_) {
      await Future.delayed(const Duration(milliseconds: 120));
    }
  }
  return false;
}

/// 单节点 Xray 进程管理，逻辑对齐桌面端 XrayProc。
class XrayProc {
  Process? _proc;
  int _port = 0;
  String _note = '未启动';
  String _proxyIp = '';
  bool _running = false;

  bool get running => _running;
  int get port => _port;
  String get note => _note;
  String get proxyIp => _proxyIp;

  Future<void> start(Vless v, {ProxyIp? proxy}) async {
    await stop();

    final exePath = await Bins.path('xray');
    final dir = await Paths.xray();
    final port = await freePort();

    var path = v.wsPath;
    if (proxy != null && pathProxyIp(path) != null) {
      path = replacePathIp(path, proxy);
    }
    final effective = Vless(
      uuid: v.uuid,
      host: v.host,
      port: v.port,
      network: v.network,
      security: v.security,
      sni: v.sni,
      wsHost: v.wsHost,
      wsPath: path,
      alpn: v.alpn,
      fingerprint: v.fingerprint,
      mode: v.mode,
      name: v.name,
    );

    final cfgFile = File('${dir.path}/config.json');
    await cfgFile.writeAsString(xrayConfigJson(effective, port), flush: true);

    final proc = await Process.start(
      exePath,
      ['run', '-c', cfgFile.path],
      workingDirectory: dir.path,
    );
    _proc = proc;

    // 丢弃输出，避免管道阻塞
    proc.stdout.listen((_) {});
    proc.stderr.listen((_) {});

    final ready = await waitPort(port);
    if (!ready) {
      proc.kill();
      _proc = null;
      _running = false;
      throw Exception('xray 未能在 8 秒内监听 127.0.0.1:$port（检查链接是否有效）');
    }

    _port = port;
    _running = true;
    _note = '已连接';
    _proxyIp = proxy?.key ?? '';

    unawaited(proc.exitCode.then((_) {
      if (identical(_proc, proc)) {
        _running = false;
        _note = '进程已退出';
        _proc = null;
      }
    }));
  }

  Future<void> stop() async {
    final proc = _proc;
    _proc = null;
    _running = false;
    if (proc != null) {
      proc.kill(ProcessSignal.sigkill);
    }
  }

  /// 供「测试线路」使用：用现成配置启动（批量模式）。
  Future<void> startWithConfig(String configPath) async {
    await stop();
    final exePath = await Bins.path('xray');
    final dir = await Paths.xray();
    final proc = await Process.start(
      exePath,
      ['run', '-c', configPath],
      workingDirectory: dir.path,
    );
    _proc = proc;
    proc.stdout.listen((_) {});
    proc.stderr.listen((_) {});
    _running = true;
    _note = '批量模式';
    unawaited(proc.exitCode.then((_) {
      if (identical(_proc, proc)) {
        _running = false;
        _note = '进程已退出';
        _proc = null;
      }
    }));
  }
}

/// 批量配置：每个节点一个入站+出站，与桌面端 buildBatchConfig 对齐。
String buildBatchConfig(List<(Vless, int)> nodes) {
  final inbounds = <Map<String, dynamic>>[];
  final outbounds = <Map<String, dynamic>>[];
  final rules = <Map<String, dynamic>>[];

  for (var i = 0; i < nodes.length; i++) {
    final (v, port) = nodes[i];
    final inTag = 'in-$i';
    final outTag = 'out-$i';

    inbounds.add({
      'tag': inTag,
      'listen': '127.0.0.1',
      'port': port,
      'protocol': 'mixed',
      'settings': {'auth': 'noauth', 'udp': true},
      'sniffing': {
        'enabled': true,
        'destOverride': ['http', 'tls'],
      },
    });

    final cfg = buildXrayConfig(v, port);
    final proxy = (cfg['outbounds'] as List).first as Map<String, dynamic>;
    outbounds.add({...proxy, 'tag': outTag});

    rules.add({
      'type': 'field',
      'inboundTag': [inTag],
      'outboundTag': outTag,
    });
  }

  outbounds.addAll([
    {'tag': 'direct', 'protocol': 'freedom'},
    {'tag': 'block', 'protocol': 'blackhole'},
  ]);

  return const JsonEncoder.withIndent('  ').convert({
    'log': {'loglevel': 'warning'},
    'inbounds': inbounds,
    'outbounds': outbounds,
    'routing': {'domainStrategy': 'AsIs', 'rules': rules},
  });
}
