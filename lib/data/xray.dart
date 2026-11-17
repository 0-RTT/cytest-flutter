import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/bin.dart';
import '../core/paths.dart';
import 'vless.dart';

/// 等待端口开始监听的上限。
const Duration _kPortTimeout = Duration(seconds: 8);

/// 二进制自检（`xray version`）超时。
const Duration _kSelfCheckTimeout = Duration(seconds: 3);

/// 环形缓冲保留的输出行数。
const int _kOutputLines = 40;

/// 进程输出环形缓冲：stdout 与 stderr 合流，只保留最近 [capacity] 行。
///
/// 以前这里用 `proc.stdout.listen((_) {})` 把输出全丢掉，启动失败时用户
/// 只能看到「未能在 8 秒内监听」，完全不知道 xray 自己报了什么。
class _OutputRing {
  /// 最多保留的行数。
  static const int capacity = _kOutputLines;

  final List<String> _lines = <String>[];

  void add(String line) {
    final text = line.trimRight();
    if (text.isEmpty) return;
    _lines.add(text);
    while (_lines.length > capacity) {
      _lines.removeAt(0);
    }
  }

  void clear() => _lines.clear();

  List<String> get lines => List<String>.unmodifiable(_lines);

  /// 拼进异常消息的尾部输出。
  String get tail => _lines.isEmpty ? '（无输出）' : _lines.join('\n');
}

/// 单行待拼接缓冲的上限（字符数）：超过就当作一行先吐出去，避免无限膨胀。
const int _kMaxPendingLineChars = 8192;

/// 把字节流按行切分后送进 [sink]，跨 chunk 的半行缓存到下次再拼。
///
/// 返回的 Future 在输入流结束时完成，方便调用方（和测试）等最后一行落地。
/// 公开仅为可测试/可复用：切行规则（含超长行）在 `test/xray_test.dart` 里有断言。
Future<void> pumpLines(
  Stream<List<int>> stream,
  void Function(String line) sink,
) {
  final done = Completer<void>();
  var pending = '';
  stream.listen(
    (chunk) {
      pending += utf8.decode(chunk, allowMalformed: true);
      final cut = pending.lastIndexOf('\n');
      if (cut < 0) {
        // 还没有换行：单行过长时强制吐出去，避免缓冲区无限膨胀
        if (pending.length > _kMaxPendingLineChars) {
          sink(pending);
          pending = '';
        }
        return;
      }
      final head = pending.substring(0, cut);
      pending = pending.substring(cut + 1);
      for (final line in head.split('\n')) {
        sink(line);
      }
    },
    onError: (Object _) {},
    onDone: () {
      if (pending.trim().isNotEmpty) sink(pending);
      pending = '';
      if (!done.isCompleted) done.complete();
    },
    cancelOnError: false,
  );
  return done.future;
}

/// 按 errno 判型（与系统语言无关），未命中返回 null 交给文案匹配兜底。
///
/// 只看 errno 是因为 `ProcessException.message` 会随 locale 变化：
/// zh-CN 下缺失文件是「系统找不到指定的文件。」，靠英文 contains 会全部漏判。
/// 目标平台 Android 的 errno 与 POSIX 一致（2/13/8）。
String? _describeErrno(int errno, String detail, String codeText) {
  switch (errno) {
    case 2: // POSIX ENOENT / Windows ERROR_FILE_NOT_FOUND
      return '文件不存在 —— $detail$codeText';
    case 13: // POSIX EACCES
      return 'Permission denied —— 二进制没有可执行权限'
          '（nativeLibraryDir 里是否已解压出实体文件？需要 extractNativeLibs=true）'
          ' —— $detail$codeText';
    case 8: // POSIX ENOEXEC
      return 'Exec format error —— 二进制与当前 CPU 架构不匹配'
          '（应放在 jniLibs/arm64-v8a，且必须是 ET_DYN 的 PIE 可执行文件）'
          ' —— $detail$codeText';
  }
  return null;
}

/// 把 [ProcessException] 翻译成三种典型情况，方便用户自己判断。
///
/// 先按 errno 判型（locale 无关），再回落到英文文案匹配。
String describeProcessError(ProcessException e) {
  final detail = e.message.isEmpty ? 'ProcessException' : e.message;
  final codeText = e.errorCode == 0 ? '' : '（errno ${e.errorCode}）';

  final byErrno = _describeErrno(e.errorCode, detail, codeText);
  if (byErrno != null) return byErrno;

  final msg = detail.toLowerCase();
  if (msg.contains('no such file') ||
      msg.contains('not found') ||
      msg.contains('cannot find')) {
    return '文件不存在 —— $detail$codeText';
  }
  if (msg.contains('permission denied') || msg.contains('errno = 13')) {
    return 'Permission denied —— 二进制没有可执行权限'
        '（nativeLibraryDir 里是否已解压出实体文件？需要 extractNativeLibs=true）'
        ' —— $detail$codeText';
  }
  if (msg.contains('exec format error') || msg.contains('errno = 8')) {
    return 'Exec format error —— 二进制与当前 CPU 架构不匹配'
        '（应放在 jniLibs/arm64-v8a，且必须是 ET_DYN 的 PIE 可执行文件）'
        ' —— $detail$codeText';
  }
  return '$detail$codeText';
}

/// 起进程前自检：跑一次 `xray version`，3 秒超时。
///
/// 任何一种失败都抛异常（带具体原因），调用方不要继续启动进程。
/// [onLine] 收到子进程逐行输出，便于调用方把自检失败原因也存进环形缓冲。
/// 返回版本号首行，仅用于日志。
Future<String> checkXrayBinary(
  String exePath, {
  void Function(String line)? onLine,
}) async {
  final Process proc;
  try {
    // 这里抛的 ProcessException 是本函数最核心的价值：把
    // 「文件不存在 / 权限被拒 / 架构不匹配」翻译成人话。
    proc = await Process.start(exePath, <String>['version']);
  } on ProcessException catch (e) {
    throw Exception('xray 无法执行（$exePath）：${describeProcessError(e)}');
  } catch (e) {
    throw Exception('xray 自检异常（$exePath）：$e');
  }

  // 关掉 stdin（等价于 `Process.run` 的默认行为）：有些程序（例如 Windows 的
  // cmd.exe）会一直等 stdin 的 EOF，不关就会把自检挂到超时才返回。
  try {
    await proc.stdin.close();
  } catch (_) {
    // 进程已自行退出时管道可能已关闭，忽略
  }

  // 必须持续消费两条管道：不读会把子进程卡在 write 上，
  // 让「自检」自己变成新的卡死点。
  final stdoutText = StringBuffer();
  final stderrText = StringBuffer();
  final drains = <Future<void>>[
    pumpLines(proc.stdout, (line) {
      stdoutText.writeln(line);
      onLine?.call(line);
    }),
    pumpLines(proc.stderr, (line) {
      stderrText.writeln(line);
      onLine?.call(line);
    }),
  ];

  // `Future.timeout` 只是「不再等待」，不会回收子进程；ABI 不匹配卡在 exec 前时
  // 会留下一个僵留进程，所以超时必须自己 sigkill，且先把管道读完再判定。
  int? exit;
  try {
    exit = await proc.exitCode.timeout(_kSelfCheckTimeout);
  } on TimeoutException {
    proc.kill(ProcessSignal.sigkill);
  }

  for (final drain in drains) {
    await drain.timeout(const Duration(seconds: 1), onTimeout: () {});
  }

  if (exit == null) {
    throw Exception('xray 自检超时：`version` ${_kSelfCheckTimeout.inSeconds} 秒内没有返回'
        '（二进制可能损坏，或与机型 ABI 不匹配）');
  }

  if (exit != 0) {
    final out = '$stdoutText$stderrText'.trim();
    throw Exception('xray 自检失败（exitCode=$exit）：'
        '${out.isEmpty ? "无输出" : out}');
  }

  final first = stdoutText.toString().trim().split('\n').first.trim();
  return first.isEmpty ? 'xray' : first;
}

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

Future<bool> waitPort(int port, {Duration timeout = _kPortTimeout}) async {
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
  final _OutputRing _out = _OutputRing();
  int _port = 0;
  String _note = '未启动';
  String _proxyIp = '';
  bool _running = false;

  bool get running => _running;
  int get port => _port;
  String get note => _note;
  String get proxyIp => _proxyIp;

  /// 最近 40 行 stdout/stderr（合流，按到达顺序），排障用。
  List<String> get lastOutput => _out.lines;

  /// 自检二进制，并把失败状态落到 [note]（异常原样抛给调用方）。
  ///
  /// 自检输出同样写进 [_out]，这样即使进程没起来，lastOutput 里也有内容可看。
  Future<void> _selfCheck(String exePath) async {
    try {
      await checkXrayBinary(exePath, onLine: _out.add);
    } catch (_) {
      _note = '自检失败';
      rethrow;
    }
  }

  Future<void> start(Vless v, {ProxyIp? proxy}) async {
    await stop();
    _out.clear();

    final exePath = await Bins.path('xray');
    final dir = await Paths.xray();
    final port = await freePort();

    // 起进程之前先确认这个二进制真的能跑。失败直接把
    // 「文件不存在 / 权限被拒 / 架构不匹配」指出来，不再往下走。
    // 自检的输出也进同一个环形缓冲，用户点「查看日志」时能看到完整链路。
    await _selfCheck(exePath);

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

    // 保留输出（不再丢弃）：既避免管道写满阻塞子进程，也让失败时能取到原因。
    unawaited(pumpLines(proc.stdout, _out.add));
    unawaited(pumpLines(proc.stderr, _out.add));

    final ready = await waitPort(port);
    if (!ready) {
      // 给管道一点时间把最后几行刷进环形缓冲，再拼错误消息
      await Future.delayed(const Duration(milliseconds: 150));
      proc.kill(ProcessSignal.sigkill);
      _proc = null;
      _running = false;
      _note = '启动失败';
      throw Exception(
        'xray 未能在 ${_kPortTimeout.inSeconds} 秒内监听 127.0.0.1:$port'
        '（检查链接是否有效）\n—— xray 最后输出 ——\n${_out.tail}',
      );
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
  ///
  /// 和 [start] 一样先自检二进制：这条入口就是「测试线路」按钮，
  /// 过去失败时同样是一句黑盒错误，用户拿不到任何原因。
  Future<void> startWithConfig(String configPath) async {
    await stop();
    _out.clear();
    final exePath = await Bins.path('xray');
    final dir = await Paths.xray();

    await _selfCheck(exePath);

    final proc = await Process.start(
      exePath,
      ['run', '-c', configPath],
      workingDirectory: dir.path,
    );
    _proc = proc;
    unawaited(pumpLines(proc.stdout, _out.add));
    unawaited(pumpLines(proc.stderr, _out.add));
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
