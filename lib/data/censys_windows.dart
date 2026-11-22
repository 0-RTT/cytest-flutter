import 'dart:async';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/paths.dart';
import 'censys_exception.dart';
import 'censys_json.dart' show censysJsonOrNull;

/// Windows 版抓取：进程内 **Headless WebView2**（不挂 UI、不抢焦点）。
///
/// 为什么不是纯 HTTP：站点是 Fastly 分级放行，纯 HTTP 在 TLS 层就被拒；
/// 必须是真实浏览器内核跑完挑战、自己把 JSON 渲染进 `<pre>`。
/// Android 侧用系统 WebView（不 attach 也能过），Windows 侧对应 WebView2。
///
/// 与 Android 实现的差异（有意为之）：
/// * 代理只能**在环境创建时**通过 `--proxy-server` 指定，不能在运行中切换 ——
///   所以按端口缓存环境；换出口时 Dart 侧会重启 xray 拿到新端口，这里就新建一个。
/// * 每个端口一个 userDataFolder：WebView2 不允许同一目录挂两套不同参数的浏览器进程。
const String _censysUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

const Duration _poll = Duration(milliseconds: 400);
const int _stableRounds = 2;
const int _chunk = 6000;
const int _previewChars = 300;

/// Fastly 挑战页特征（与 Android 侧同一份清单）。
const List<String> _challengeMarks = <String>[
  '/_fs-ch-',
  'fst-post-back',
  '_fs_ch_st',
  'just a moment',
  'checking your browser',
];

const String _textExpr = "var p=document.querySelector('pre');"
    "var t=p?p.textContent:(document.body?document.body.textContent:'');";

String get _headJs => "(function(){try{$_textExpr return t.slice(0,4096)}catch(e){return ''}})()";
String get _lengthJs => "(function(){try{$_textExpr return t.length}catch(e){return -1}})()";
String _sliceJs(int from, int to) =>
    "(function(){try{$_textExpr return t.slice($from,$to)}catch(e){return ''}})()";

/// 环境缓存：key 为代理端口（0 = 直连）。
final Map<int, WebViewEnvironment> _envs = <int, WebViewEnvironment>{};

Future<WebViewEnvironment> _environment(int proxyPort, {String? proxyServer}) async {
  final cached = _envs[proxyPort];
  if (cached != null) return cached;

  final root = await Paths.root();
  // 每个端口独立 profile：同一个 userDataFolder 不能挂两套不同 --proxy-server。
  final profile = Directory('${root.path}/webview2/p$proxyPort');
  if (!await profile.exists()) await profile.create(recursive: true);

  final env = await WebViewEnvironment.create(
    settings: WebViewEnvironmentSettings(
      userDataFolder: profile.path,
      additionalBrowserArguments: () {
        final proxy = proxyServer ??
            (proxyPort > 0 ? 'http://127.0.0.1:$proxyPort' : null);
        return proxy == null
            ? '--disable-features=msWebOOUI,msPdfOOUI'
            : '--proxy-server=$proxy --disable-features=msWebOOUI,msPdfOOUI';
      }(),
    ),
  );
  _envs[proxyPort] = env;
  return env;
}

bool _looksChallenged(String text) {
  final lower = text.toLowerCase();
  return _challengeMarks.any((m) => lower.contains(m.toLowerCase()));
}

/// 用 Headless WebView2 抓 Censys 搜索结果，返回 JSON 文本。
///
/// 抛 [CensysNativeException]：缺 Runtime / 超时 / 挑战未过 / 返回不是搜索结果。
Future<String> fetchCensysSearchWindows({
  required String query,
  int? proxyPort,
  Duration timeout = const Duration(seconds: 25),
  void Function(String stage)? trace,
  String? proxyServer,
}) async {
  final port = proxyPort ?? 0;
  final url = 'https://platform.censys.io/api/search?q=${Uri.encodeComponent(query)}';

  trace?.call('env:start port=$port');
  final WebViewEnvironment env;
  try {
    env = await _environment(port, proxyServer: proxyServer);
    trace?.call('env:ok');
  } on Object catch (e) {
    throw CensysNativeException(
      'WebView2 初始化失败（Windows 需要 WebView2 运行时）：$e',
      details: <Object?, Object?>{'proxyMode': port > 0 ? 'proxy' : 'direct'},
    );
  }

  final headless = HeadlessInAppWebView(
    webViewEnvironment: env,
    initialUrlRequest: URLRequest(url: WebUri(url)),
    initialSettings: InAppWebViewSettings(
      userAgent: _censysUa,
      javaScriptEnabled: true,
      domStorageEnabled: true,
      transparentBackground: true,
      useShouldOverrideUrlLoading: false,
    ),
  );

  try {
    trace?.call('run:start');
    await headless.run();
    trace?.call('run:ok');
    final ctrl = headless.webViewController;
    if (ctrl == null) {
      throw const CensysNativeException('WebView2 没有创建出控制器');
    }

    final deadline = DateTime.now().add(timeout);
    var lastLen = -1;
    var stable = 0;
    var reloaded = false;
    var sawChallenge = false;
    var preview = '';

    var round = 0;
    while (DateTime.now().isBefore(deadline)) {
      round++;
      final head = await _js(ctrl, _headJs) ?? '';
      if (round <= 3 || round % 10 == 0) {
        final brief = head.replaceAll('\n', ' ');
        trace?.call(
          'poll:$round len=${head.length} head=${brief.substring(0, brief.length > 60 ? 60 : brief.length)}',
        );
      }

      if (head.trim().isEmpty) {
        await Future<void>.delayed(_poll);
        continue;
      }

      // 不是 JSON：大概率是挑战页。拿到 clearance cookie 后 reload 一次
      // （挑战通过时页面会自己重新请求，但当前文档不会自动重试）。
      if (!head.trimLeft().startsWith('{')) {
        preview = head.length > _previewChars
            ? '${head.substring(0, _previewChars)}…'
            : head;
        if (_looksChallenged(head)) sawChallenge = true;

        final cookies = await CookieManager.instance().getCookies(url: WebUri(url));
        final clearance = cookies.any((c) => c.name.contains('_fs_ch_st_'));
        if (clearance) {
          sawChallenge = true;
          if (!reloaded) {
            reloaded = true;
            sawChallenge = false;
            stable = 0;
            lastLen = -1;
            await ctrl.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
          }
        }
        await Future<void>.delayed(_poll);
        continue;
      }

      // 看起来是 JSON：等长度稳定两轮再整段读，避免读到半截。
      final lenRaw = await _js(ctrl, _lengthJs) ?? '';
      final total = int.tryParse(lenRaw.trim()) ?? -1;
      if (total <= 0) {
        await Future<void>.delayed(_poll);
        continue;
      }
      if (total != lastLen) {
        lastLen = total;
        stable = 0;
        await Future<void>.delayed(_poll);
        continue;
      }
      stable += 1;
      if (stable < _stableRounds) {
        await Future<void>.delayed(_poll);
        continue;
      }

      final body = await _readAll(ctrl, total);
      if (body.trimRight().endsWith('}')) {
        final json = censysJsonOrNull(body);
        if (json != null) return json;
      }
      lastLen = -1;
      stable = 0;
      await Future<void>.delayed(_poll);
    }

    throw CensysNativeException(
      sawChallenge
          ? 'WebView2 没能通过 Censys 挑战（出口可能已被标记）'
          : 'WebView2 抓取超时（${timeout.inSeconds}s）',
      details: <Object?, Object?>{
        'proxyMode': port > 0 ? 'proxy' : 'direct',
        'sawChallenge': sawChallenge,
        'preview': preview,
      },
    );
  } finally {
    // 每次抓取都销毁页面：常驻会一直占内存，且下一轮要换端口就只能换环境。
    unawaited(headless.dispose());
  }
}

/// 分片读回整段正文（WebView2 的脚本返回值同样有长度上限）。
Future<String> _readAll(InAppWebViewController ctrl, int total) async {
  final buffer = StringBuffer();
  for (var from = 0; from < total; from += _chunk) {
    final to = (from + _chunk) > total ? total : from + _chunk;
    final part = await _js(ctrl, _sliceJs(from, to));
    if (part == null || part.isEmpty) break;
    buffer.write(part);
  }
  return buffer.toString();
}

/// `evaluateJavascript` 没有内置超时：WebView2 在页面重定向 / 渲染进程切换时
/// 可能永远不回调，裸 await 会让整轮抓取卡死（表现为「一直转圈、没有超时错误」）。
/// 这里统一 4s 兜底，超时按「这一轮没拿到内容」处理。
Future<String?> _js(InAppWebViewController ctrl, String source) {
  return ctrl
      .evaluateJavascript(source: source)
      .then<String?>((v) => v?.toString())
      .timeout(const Duration(seconds: 4), onTimeout: () => null);
}
