// K2 冒烟脚本（设计文档 §8 T02 验收 6b / §11 A3）—— **一次性工具，不进业务代码**。
//
// 为什么需要它：R5 的核心未知量是「Dart 的 `HttpClient.findProxy` 走
// `PROXY 127.0.0.1:port` 时，HTTPS 到底能不能通过 CONNECT 打出去」。
// `curl -x` 能过**不代表** Dart 能过（两者的 CONNECT/TLS 实现完全不同），
// 所以必须在真机（或任意有可用代理的机器）上单独验一次 [LinkProbe.latency]。
//
// 用法：
//   # 1) 真机：先在 App 里点「测试全部线路」，让批量 xray 起在 20000~2000N，
//   #    然后用下面的命令把某个入站口当代理去探真实测速地址
//   dart run tool/smoke_probe.dart --port 20000
//
//   # 2) 桌面快速验签（用本机已在跑的代理，例如 v2rayN / mihomo 的混合口）：
//   dart run tool/smoke_probe.dart --port 10808 --mode both
//
//   # 3) 只看隧道自体（等价于 6a 的 curl），把 --mode 换成 latency 即可
//   dart run tool/smoke_probe.dart --port 20000 --url https://е.eu.org/300.zip
//
// 退出码：0 = 通过（latency 拿到 TTFB 且无 error；speed 模式下还要求 speedMib > 0）
//         1 = 未通过（打印失败原因）
//         2 = 参数错误
//
// 注意：脚本只做「测量」，不启停 xray 进程。隧道由调用方负责（App 的测速按钮
// 或手动 `xray run -c batch.json`），这样失败时能明确区分「隧道没起」与
// 「Dart 发不出去」——这两件事的排障方向完全不同（K2 要求不得静默降级）。
import 'dart:io';

import 'package:cytest/core/idna.dart';
import 'package:cytest/data/link_probe.dart';

/// 解析出的命令行参数。
class _Args {
  _Args({
    required this.port,
    required this.url,
    required this.latencyUrl,
    required this.mode,
  });

  /// 本机代理/入站端口。
  final int port;

  /// 测速（速度阶段）地址（可含 IDN）。
  final String url;

  /// 延迟阶段地址（默认小端点；与速度地址分开，见 kDefaultLatencyUrl）。
  final String latencyUrl;

  /// `latency` / `speed` / `both`。
  final String mode;

  bool get wantLatency => mode == 'latency' || mode == 'both';

  bool get wantSpeed => mode == 'speed' || mode == 'both';

  /// 解析失败返回 null，由调用方打印用法。
  static _Args? parse(List<String> argv) {
    var port = 20000;
    var url = kDefaultSpeedUrl;
    var latencyUrl = kDefaultLatencyUrl;
    var mode = 'both';
    for (var i = 0; i < argv.length; i++) {
      final arg = argv[i];
      String? valueOf(String flag) {
        if (arg == flag && i + 1 < argv.length) return argv[++i];
        if (arg.startsWith('$flag=')) return arg.substring(flag.length + 1);
        return null;
      }

      if (arg == '-h' || arg == '--help') return null;
      final p = valueOf('--port');
      if (p != null) {
        final parsed = int.tryParse(p);
        if (parsed == null || parsed <= 0 || parsed > 65535) return null;
        port = parsed;
        continue;
      }
      final u = valueOf('--url');
      if (u != null) {
        url = u;
        continue;
      }
      final lu = valueOf('--latency-url');
      if (lu != null) {
        latencyUrl = lu;
        continue;
      }
      final m = valueOf('--mode');
      if (m != null) {
        if (m != 'latency' && m != 'speed' && m != 'both') return null;
        mode = m;
        continue;
      }
      // 未知参数
      if (arg.startsWith('-')) return null;
      // 允许把 URL 作为位置参数直接给
      url = arg;
    }
    return _Args(port: port, url: url, latencyUrl: latencyUrl, mode: mode);
  }
}

void _usage() {
  stdout.writeln('K2 冒烟：用 LinkProbe 探本机某个代理/入站口');
  stdout.writeln('');
  stdout.writeln('  dart run tool/smoke_probe.dart [--port 20000] '
      '[--url $kDefaultSpeedUrl] '
      '[--latency-url $kDefaultLatencyUrl] [--mode latency|speed|both]');
  stdout.writeln('');
  stdout.writeln('  --port        本机代理端口（默认 20000，即批量 xray 的第一个入站）');
  stdout.writeln('  --url         测速地址（默认 $kDefaultSpeedUrl）');
  stdout.writeln('  --latency-url 延迟地址（默认 $kDefaultLatencyUrl）');
  stdout.writeln('  --mode        latency = 只测 TTFB；speed = 只测吞吐；both = 都测（默认）');
}

Future<int> _run(_Args args) async {
  // ---- 0) K1 自证：先证明探测目标的主机名是 ASCII 的 ----
  final Uri target;
  final Uri latencyTarget;
  try {
    target = probeUri(args.url);
    latencyTarget = probeUri(args.latencyUrl);
  } on UnsupportedIdnException catch (e) {
    stderr.writeln('[FAIL] 地址无法 ASCII 化：$e');
    return 1;
  } on FormatException catch (e) {
    stderr.writeln('[FAIL] 地址不合法：${e.message}');
    return 1;
  }

  final asciiHost = target.host;
  final hostIsAscii = RegExp(r'^[\x00-\x7F]+$').hasMatch(asciiHost);
  final latencyHostIsAscii =
      RegExp(r'^[\x00-\x7F]+$').hasMatch(latencyTarget.host);
  stdout.writeln('测速地址 : ${target.toString()}');
  stdout.writeln('延迟地址 : ${latencyTarget.toString()}');
  stdout.writeln('ASCII 主机: $asciiHost'
      '${hostIsAscii ? '  ✓ 全 ASCII' : '  ✗ 含非 ASCII（K1 不合格）'}');
  stdout.writeln('本机代理 : 127.0.0.1:${args.port}');
  stdout.writeln('');
  if (!hostIsAscii || !latencyHostIsAscii) {
    stderr.writeln('[FAIL] 主机名没有 ASCII 化，拒绝继续探测（K1）');
    return 1;
  }

  var allPass = true;

  // ---- 1) TTFB（6b 的核心断言：ttfbMs > 0 && error == null）----
  if (args.wantLatency) {
    final probe = LinkProbe(
      speedUrl: args.url,
      latencyUrl: args.latencyUrl,
      localPort: args.port,
    );
    stdout.writeln('[latency] 开始（看门狗 ${kLatencyTimeout.inSeconds}s）…');
    final outcome = await probe.latency();
    stdout.writeln('  ttfbMs   = ${outcome.ttfbMs}');
    stdout.writeln('  error    = ${outcome.error ?? '（无）'}');
    stdout.writeln('  elapsed  = ${outcome.elapsedMs} ms');
    // 分项计时：延迟读数可疑时先看这一行（建连 / 响应头 / 首字节）。
    stdout.writeln('  timings  = ${outcome.timings?.summary ?? '（未采集）'}');
    final pass = outcome.ttfbMs > 0 && outcome.error == null;
    allPass = allPass && pass;
    stdout.writeln(pass ? '  ✓ PASS' : '  ✗ FAIL');
    stdout.writeln('');
  }

  // ---- 2) 吞吐（MiB/s，首字节后 3s / 64MiB 窗口）----
  if (args.wantSpeed) {
    final probe = LinkProbe(
      speedUrl: args.url,
      latencyUrl: args.latencyUrl,
      localPort: args.port,
    );
    stdout.writeln('[speed] 开始（看门狗 ${kSpeedTimeout.inSeconds}s）…');
    final outcome = await probe.speed();
    stdout.writeln('  ttfbMs   = ${outcome.ttfbMs}');
    stdout.writeln(
        '  speedMib = ${outcome.speedMib?.toStringAsFixed(2) ?? '未测'}');
    stdout.writeln('  error    = ${outcome.error ?? '（无）'}');
    stdout.writeln('  elapsed  = ${outcome.elapsedMs} ms');
    stdout.writeln('  timings  = ${outcome.timings?.summary ?? '（未采集）'}');
    // 预热未完成算「未测」，不算通过也不算出错：K2 只要求 TTFB 能出数。
    final pass = outcome.ttfbMs > 0 && outcome.error == null;
    allPass = allPass && pass;
    stdout.writeln(pass ? '  ✓ PASS' : '  ✗ FAIL');
    stdout.writeln('');
  }

  stdout.writeln(allPass
      ? '==> K2 结论：PASS —— Dart 侧 TTFB 能出数，方案 A（HttpClient + '
          'findProxy/CONNECT）可用，可以开 T03'
      : '==> K2 结论：FAIL —— 不要继续 T03，不要静默降级到方案 B，'
          '把上面的 error 原文报给 team-lead');
  return allPass ? 0 : 1;
}

Future<void> main(List<String> argv) async {
  final args = _Args.parse(argv);
  if (args == null) {
    _usage();
    exit(2);
  }
  int code;
  try {
    code = await _run(args);
  } catch (e) {
    // 探测层已经把网络异常翻译成 outcome.error；能走到这里的只有脚本自身的
    // 编程错误，原样打出来，不要吞。
    stderr.writeln('[ERROR] 冒烟脚本异常：$e');
    code = 1;
  }
  // 显式退出：HttpClient / Process 可能留下活跃句柄，不 exit 会让脚本挂住。
  exit(code);
}
