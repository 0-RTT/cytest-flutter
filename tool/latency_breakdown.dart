// 延迟口径取证脚本（Bug B）—— **一次性诊断工具，不进业务代码**。
//
// 背景：用户反馈「链路测速的延迟读数远大于 v2rayN 的真连接延迟」。修复前
// `LinkProbe.latency()` 的口径是：用**测速地址**（`300.zip` 大文件）、
// `followRedirects = true`、以 body 首字节作为 TTFB。本脚本用**纯本地**的服务
// 把三条可疑因素逐个量出来，不需要外网、不需要 xray：
//
//   1. 跟随跳转 vs 不跟随跳转：`HttpClient` 会对 Location 重新建连
//      （`_http/http_impl.dart:693` → `:3026`，TLS 在 `:2520`），所以 TTFB
//      会多出**一整套** CONNECT + TLS + 请求。脚本用 `--hop-delay` 人工注入
//      「一次跨境往返」的时间来放大这个差值，并统计服务端看到的 TCP 连接数。
//   2. 大文件端点的首字节 vs 204 小端点：用 `--first-byte-delay` 模拟服务端
//      缓冲（大文件端点常见），量出它对 TTFB 的贡献。
//   3. 分项计时是否可用：`getUrl` 返回（建连完成）、`close()` 返回（响应头）、
//      首个 chunk（首字节）三个时刻分别打点。
//
// 用法：
//   dart run tool/latency_breakdown.dart
//   dart run tool/latency_breakdown.dart --runs 5 --hop-delay 150 --first-byte-delay 50
//
// 退出码：0 = 跑完（不代表通过/失败，这是取证工具）；2 = 参数非法。
//
// 说明：本机 loopback 上没有真实 TCP/TLS 握手成本，所以**绝对数值不可外推**到
// 真机；能外推的是「结构」——跳转会让往返次数从 1 变 2、大文件端点会让首字节
// 额外等待服务端缓冲。真机上的绝对值需要 `tool/smoke_probe.dart` + 真实线路。
import 'dart:async';
import 'dart:io';

/// 一个「扮演本机 xray 入站口」的本地 HTTP 服务。
///
/// `HttpClient` 在 `findProxy` 返回 `PROXY 127.0.0.1:port` 时，对 `http://` 目标
/// 会发 **absolute-form**（`GET http://host/path HTTP/1.1`）给代理，所以一个普通
/// `HttpServer` 就能按路径扮演不同端点。
class _FakeInbound {
  _FakeInbound._(
    this._server,
    this.firstByteDelayMs,
    this.hopDelayMs,
    this.redirectTo,
  );

  final HttpServer _server;
  final int firstByteDelayMs;
  final int hopDelayMs;

  /// `/hop` 的跳转目标；null = 用固定的跨主机地址（走代理时可以复用 socket）。
  final String? redirectTo;

  /// 服务端看到的客户端 TCP 连接数（按对端端口去重）。
  final Set<int> clientPorts = <int>{};

  /// 各端点实际收到的请求数。
  final Map<String, int> hits = <String, int>{};

  int get port => _server.port;

  static Future<_FakeInbound> start({
    int firstByteDelayMs = 0,
    int hopDelayMs = 0,
    String? redirectTo,
  }) async {
    final inbound = _FakeInbound._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      firstByteDelayMs,
      hopDelayMs,
      redirectTo,
    );
    inbound._server.listen((HttpRequest request) {
      unawaited(inbound._handle(request).catchError((Object _) {}));
    });
    return inbound;
  }

  Future<void> _handle(HttpRequest request) async {
    final info = request.connectionInfo;
    if (info != null) clientPorts.add(info.remotePort);

    final path = request.uri.path;
    hits[path] = (hits[path] ?? 0) + 1;
    final response = request.response;

    // 「204 小端点」：立刻回，无 body。
    if (path.contains('generate_204')) {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }

    // 「302 跳到另一个主机」：模拟大文件端点常见的换 CDN 主机。
    // hopDelayMs 代表「第二套 CONNECT+TLS+请求」在真实链路上的耗时。
    if (path.contains('hop')) {
      await Future<void>.delayed(Duration(milliseconds: hopDelayMs));
      response.statusCode = HttpStatus.found;
      response.headers.set(
        HttpHeaders.locationHeader,
        redirectTo ?? 'http://cdn.other.test/generate_204',
      );
      response.contentLength = 0;
      await response.close();
      return;
    }

    // 「大文件端点」：firstByteDelayMs 模拟服务端/链路的首字节缓冲。
    await Future<void>.delayed(Duration(milliseconds: firstByteDelayMs));
    const bodyBytes = 300 * 1024;
    response.statusCode = 200;
    response.contentLength = bodyBytes;
    response.add(List<int>.filled(bodyBytes, 0x41));
    await response.close();
  }

  Future<void> close() => _server.close(force: true);
}

/// 一次测量的结果。
class _Sample {
  _Sample({
    required this.connectMs,
    required this.headerMs,
    required this.firstByteMs,
    required this.connections,
  });

  final int connectMs;
  final int headerMs;
  final int firstByteMs;

  /// 这次测量期间服务端看到的客户端连接数。
  final int connections;

  @override
  String toString() => '建连=$connectMs 响应头=$headerMs 首字节=$firstByteMs '
      '新增连接=$connections';
}

/// 用「与修复前/后完全一致」的手法测一次：`HttpClient` + `findProxy`。
Future<_Sample> _measure({
  required int port,
  required String url,
  required bool followRedirects,
  required _FakeInbound inbound,
  required bool freshClient,
  bool useProxy = true,
  _FakeInbound? hopInbound,
}) async {
  // 第二跳可能落在**另一个**服务对象上，两条连接的计数必须一起算，
  // 否则「跨端口跳转新建了连接」这件事会被漏量（踩过）。
  final before = inbound.clientPorts.length +
      (hopInbound?.clientPorts.length ?? 0);
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..findProxy = (Uri _) => useProxy ? 'PROXY 127.0.0.1:$port' : 'DIRECT';
  final sw = Stopwatch()..start();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final connectMs = sw.elapsedMilliseconds;
    request.followRedirects = followRedirects;
    final response = await request.close();
    final headerMs = sw.elapsedMilliseconds;
    var firstByteMs = -1;
    await for (final chunk in response) {
      if (chunk.isEmpty) continue;
      firstByteMs = sw.elapsedMilliseconds;
      break;
    }
    return _Sample(
      connectMs: connectMs,
      headerMs: headerMs,
      firstByteMs: firstByteMs < 0 ? headerMs : firstByteMs,
      connections: inbound.clientPorts.length +
          (hopInbound?.clientPorts.length ?? 0) -
          before,
    );
  } finally {
    client.close(force: !freshClient);
  }
}

Future<_Sample> _repeat({
  required int runs,
  required Future<_Sample> Function() once,
}) async {
  _Sample? last;
  for (var i = 0; i < runs; i++) {
    last = await once();
  }
  return last!;
}

class _Args {
  _Args({
    required this.runs,
    required this.hopDelayMs,
    required this.firstByteDelayMs,
  });

  final int runs;
  final int hopDelayMs;
  final int firstByteDelayMs;

  static _Args? parse(List<String> argv) {
    var runs = 3;
    var hopDelay = 150;
    var firstByteDelay = 50;
    for (var i = 0; i < argv.length; i++) {
      final arg = argv[i];
      String? valueOf(String flag) {
        if (arg == flag && i + 1 < argv.length) return argv[++i];
        if (arg.startsWith('$flag=')) return arg.substring(flag.length + 1);
        return null;
      }

      if (arg == '-h' || arg == '--help') return null;
      final r = valueOf('--runs');
      if (r != null) {
        final parsed = int.tryParse(r);
        if (parsed == null || parsed <= 0) return null;
        runs = parsed;
        continue;
      }
      final h = valueOf('--hop-delay');
      if (h != null) {
        final parsed = int.tryParse(h);
        if (parsed == null || parsed < 0) return null;
        hopDelay = parsed;
        continue;
      }
      final f = valueOf('--first-byte-delay');
      if (f != null) {
        final parsed = int.tryParse(f);
        if (parsed == null || parsed < 0) return null;
        firstByteDelay = parsed;
        continue;
      }
      return null;
    }
    return _Args(
      runs: runs,
      hopDelayMs: hopDelay,
      firstByteDelayMs: firstByteDelay,
    );
  }
}

void _usage() {
  stdout.writeln('延迟口径取证（Bug B）：用本地端点量「跳转」与「大文件端点」的代价');
  stdout.writeln('');
  stdout.writeln('  dart run tool/latency_breakdown.dart '
      '[--runs 3] [--hop-delay 150] [--first-byte-delay 50]');
  stdout.writeln('');
  stdout.writeln('  --runs             每组测几次（取最后一次，避免噪声）');
  stdout.writeln('  --hop-delay        模拟「一次跨境往返」（毫秒），加在 302 的响应前');
  stdout.writeln('  --first-byte-delay 模拟大文件端点的首字节缓冲（毫秒）');
}

Future<void> main(List<String> argv) async {
  final args = _Args.parse(argv);
  if (args == null) {
    _usage();
    exit(2);
  }

  final inbound = await _FakeInbound.start(
    firstByteDelayMs: args.firstByteDelayMs,
    hopDelayMs: args.hopDelayMs,
  );
  stdout.writeln('本机入站（扮演 xray 入站口）: 127.0.0.1:${inbound.port}');
  stdout.writeln('模拟跨境往返 = ${args.hopDelayMs}ms · '
      '大文件端点首字节缓冲 = ${args.firstByteDelayMs}ms · '
      '每组 ${args.runs} 次');
  stdout.writeln('');

  try {
    // ① 204 小端点 + 不跟随跳转（= 修复后的延迟口径）
    final small = await _repeat(
      runs: args.runs,
      once: () => _measure(
        port: inbound.port,
        url: 'http://target.test/generate_204',
        followRedirects: false,
        inbound: inbound,
        freshClient: true,
      ),
    );
    stdout.writeln('[A] 204 小端点（不跟随跳转）        : $small');

    // ② 302 端点 + 不跟随跳转（= 修复后的口径，且目标带跳转）
    final hopNoFollow = await _repeat(
      runs: args.runs,
      once: () => _measure(
        port: inbound.port,
        url: 'http://target.test/hop',
        followRedirects: false,
        inbound: inbound,
        freshClient: true,
      ),
    );
    stdout.writeln('[B] 302 端点（不跟随跳转）          : $hopNoFollow');

    // ③ 302 端点 + 跟随跳转（= 修复前的口径）
    final hopFollow = await _repeat(
      runs: args.runs,
      once: () => _measure(
        port: inbound.port,
        url: 'http://target.test/hop',
        followRedirects: true,
        inbound: inbound,
        freshClient: true,
      ),
    );
    stdout.writeln('[C] 302 端点（跟随跳转，旧口径）    : $hopFollow');

    // ④ 大文件端点（首字节被服务端缓冲）
    final big = await _repeat(
      runs: args.runs,
      once: () => _measure(
        port: inbound.port,
        url: 'http://target.test/300.zip',
        followRedirects: true,
        inbound: inbound,
        freshClient: true,
      ),
    );
    stdout.writeln('[D] 300.zip 大文件端点              : $big');

    // ⑤⑥ 跨端口跳转（DIRECT，不走代理）：第二跳**必须**新开一条 TCP 连接，
    //    于是「新增连接」这一列能直接证明「跟随跳转 = 多一套建连」。
    final tail = await _FakeInbound.start();
    final front = await _FakeInbound.start(
      hopDelayMs: args.hopDelayMs,
      redirectTo: 'http://127.0.0.1:${tail.port}/generate_204',
    );
    try {
      final directNoFollow = await _repeat(
        runs: args.runs,
        once: () => _measure(
          port: front.port,
          url: 'http://127.0.0.1:${front.port}/hop',
          followRedirects: false,
          inbound: front,
          hopInbound: tail,
          freshClient: true,
          useProxy: false,
        ),
      );
      stdout.writeln('[E] 跨端口跳转（不跟随，DIRECT）    : $directNoFollow');

      final directFollow = await _repeat(
        runs: args.runs,
        once: () => _measure(
          port: front.port,
          url: 'http://127.0.0.1:${front.port}/hop',
          followRedirects: true,
          inbound: front,
          hopInbound: tail,
          freshClient: true,
          useProxy: false,
        ),
      );
      stdout.writeln('[F] 跨端口跳转（跟随，DIRECT）      : $directFollow');

      stdout.writeln('');
      stdout.writeln('—— 结论（只看结构，绝对值受本机 loopback 影响）——');
      stdout.writeln('• 端点命中次数：${inbound.hits}');
      stdout.writeln('• F 与 E 的「新增连接」：${directNoFollow.connections} → '
          '${directFollow.connections}：');
      stdout.writeln('  跟随跳转**必然多一套建连**（跨主机/跨端口时连接池命中不了）。'
          '真机上延迟阶段走 https，每套建连 = CONNECT 隧道 + TLS 握手 + 请求往返'
          '（SDK `_http/http_impl.dart:693` → `:3026` → `:2520`），这就是「延迟读数翻倍」。');
      // 走 http 代理时，第二跳与第一跳共用同一个代理 socket（连接池按代理
      // 地址做 key），所以新增连接数不会变、loopback 上的时间差也在噪声里。
      // 这一条要**如实写成噪声**，不能拿它当「跳转很便宜」的证据。
      stdout.writeln('• B → C（走代理，http）：新增连接 '
          '${hopNoFollow.connections} → ${hopFollow.connections}，'
          '差值 ${hopFollow.firstByteMs - hopNoFollow.firstByteMs}ms（loopback 噪声内）：'
          'http 代理下第二跳复用了同一个 socket，'
          '所以本机量不出跳转的真实代价；真机走 https 时会话必须重新建隧道。');
      stdout.writeln('• D - A = ${big.firstByteMs - small.firstByteMs}ms：'
          '大文件端点的首字节要等对端把 body 推出来，');
      stdout.writeln('  而 v2rayN 的「真连接延迟」用的是 204 小端点，两者不可比。');
      stdout.writeln('• 因此延迟阶段必须：小端点 + 不跟随跳转 + TTFB 只取一段往返'
          '（见 LinkProbe.latency）。');
    } finally {
      await front.close();
      await tail.close();
    }
  } finally {
    await inbound.close();
  }
  // 显式退出：HttpClient/Server 可能留下活跃句柄，不 exit 会让脚本挂住。
  exit(0);
}
