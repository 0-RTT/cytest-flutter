import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../../core/settings.dart';
import '../../data/vless.dart';
import '../../state/app_state.dart';
import 'test_page.dart';

/// 获取数据：用**后台（headless）WebView** 直接打开 Censys 搜索 API，读回 JSON。
///
/// 为什么用 `HeadlessInAppWebView` 而不是可见的 `InAppWebView`：
/// - 它不走 PlatformView 机制（MethodChannel 通信、不进视图树），**不需要可见**，
///   所以页面里可以完全没有任何 WebView 区域 —— 这正是用户要的「不要预览」；
/// - 仍然复用系统 WebView 内核与 Cookie 池，能过 CDN 挑战、能带登录态请求。
///
/// 抓取顺序：**直连 API** → 判定 → 不是数据才走 **加载页面过验证 + 页面内 fetch**。
class FetchPage extends StatefulWidget {
  const FetchPage({super.key});

  @override
  State<FetchPage> createState() => _FetchPageState();
}

class _FetchPageState extends State<FetchPage> {
  static const _origin = 'https://platform.censys.io';
  static const _searchPath = '/api/search';

  /// 桌面 Chrome UA：Censys 会对明显的 WebView UA 收紧风控。
  static const _kUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// headless 实例建好、拿到 controller 的最长等待时间。
  static const _kHeadlessInitTimeout = Duration(seconds: 10);

  /// 单次页面加载（含 CDN 挑战）的最长等待时间。
  static const _kLoadTimeout = Duration(seconds: 25);

  late final TextEditingController _cql =
      TextEditingController(text: Defaults.buildQuery(Defaults.fingerprint));

  bool _fetching = false;

  /// 状态串：当前在做什么 / 走的是哪条路径。
  /// 删掉预览之后，这是用户与排障者唯一的可观测信息。
  String _diag = '待命';

  /// 最近一次走的是「直连 API」（true）还是「过验证页面」（false）。
  bool _viaApi = false;
  int? _usedProxyPort;

  /// 本次成功时用的 proxyip（null = 链接原样），只用于状态串展示。
  String? _usedProxy;
  String? _error;

  String? _payload;
  int _hits = 0;
  int _bytes = 0;
  int _costMs = 0;

  /// 结果摘要卡里展示的前几条 ip:port，在 _fetch 成功时解析一次并缓存。
  /// 不能放在 build 里解析：响应有几百 KB，每次 setState 都 jsonDecode 会明显掉帧。
  List<String> _previewTargets = const [];

  /// 解析不出 hits 时的兜底展示（原始 JSON 前 200 字符），同样在 _fetch 时算好。
  String _previewRaw = '';

  @override
  void dispose() {
    _cql.dispose();
    super.dispose();
  }

  /// 当前查询对应的 API 地址（用户要的「直接访问那个链接」）。
  String get _apiUrl =>
      '$_origin$_searchPath?q=${Uri.encodeQueryComponent(_cql.text.trim())}';

  Future<void> _fetch() async {
    final query = _cql.text.trim();
    if (query.isEmpty) {
      _toast('查询语句不能为空');
      return;
    }

    // 测速期间必须拒绝：下面会 startLine() → XrayProc.start() → stop()，
    // 会把正在跑的批量测速进程直接杀掉，用户完全看不出发生了什么。
    final appState = context.read<AppState>();
    if (appState.linkTestRunning) {
      _toast('测速进行中，请先停止测速');
      return;
    }

    setState(() {
      _fetching = true;
      _error = null;
      _payload = null;
      _hits = 0;
      _bytes = 0;
      _costMs = 0;
      _previewTargets = const [];
      _previewRaw = '';
      _diag = '准备中…';
    });

    final state = context.read<AppState>();
    final started = DateTime.now();

    // 起 Xray 并**按 ordered 顺序轮换 proxyip**：失败就记一次 failure 换下一条。
    // 原版就是这套语义（ordered/recordSuccess/recordFailure），
    // 之前这里只取 pool.first，20 条里第一条挂了就全挂。
    final hasLine = state.settings.vlessLinks.isNotEmpty;
    final candidates = hasLine ? state.orderedProxyPool : const <ProxyIp>[];
    final attempts = candidates.isEmpty
        ? const <ProxyIp?>[null] // 没有 proxyip：链接原样，只试一次
        : candidates.map<ProxyIp?>((item) => item).toList(growable: false);

    String? body;
    ProxyIp? usedProxy;
    for (final proxy in attempts) {
      int? proxyPort;
      try {
        if (hasLine) {
          await state.startLineWith(proxy);
          if (state.xray.running) proxyPort = state.xray.port;
        }
      } catch (e) {
        state.pushLog('线路启动失败（proxyip=${proxy?.key ?? "原样"}）：$e');
        await state.recordProxyResult(proxy, false);
        continue;
      }

      _usedProxyPort = proxyPort;
      if (proxyPort != null) {
        await _setProxy(proxyPort);
      } else {
        await _clearProxy();
      }

      try {
        body = await _fetchBody(state, query);
      } catch (e) {
        state.pushLog('抓取异常（proxyip=${proxy?.key ?? "原样"}）：$e');
        body = null;
      }
      await _clearProxy();

      if (body != null) {
        usedProxy = proxy;
        await state.recordProxyResult(proxy, true);
        break;
      }
      await state.recordProxyResult(proxy, false);
      if (!mounted) break;
    }
    if (usedProxy != null) _usedProxy = usedProxy.key;

    if (!mounted) return;
    if (body == null) {
      setState(() {
        _fetching = false;
        // 若抓取过程已写入更具体的原因（如「浏览器内请求失败」），不要覆盖
        _error ??= '直连 API 与「过验证页面后重试」都没有拿到数据，见日志。';
      });
      return;
    }

    var hits = 0;
    try {
      final obj = jsonDecode(body) as Map<String, dynamic>;
      final results = obj['results'] as Map<String, dynamic>?;
      hits = (results?['total_hits'] as num?)?.toInt() ?? 0;
    } catch (_) {}

    final targets = _parseHits(body);
    final rawHead = _head(body, 200);

    await state.saveArchive(body);

    if (!mounted) return;
    setState(() {
      _fetching = false;
      _payload = body;
      _hits = hits;
      _bytes = body!.length;
      _costMs = DateTime.now().difference(started).inMilliseconds;
      _previewTargets = targets;
      _previewRaw = rawHead;
      final via = _viaApi ? '直连 API 完成' : '经页面过验证完成';
      _diag = _usedProxy == null ? via : '$via · proxyip $_usedProxy';
    });
    _toast('获取成功：$hits 条');
  }

  /// 建一个后台 WebView，按「直连 → 过验证」两条路径抓数据；返回 null 表示都失败。
  ///
  /// 每次 `_fetch` 一个实例 + `finally` 里 dispose：headless 实例各自持有一个原生
  /// WebView，不复用、不释放会稳定泄漏（每个都有独立渲染进程/连接）。
  Future<String?> _fetchBody(AppState state, String query) async {
    final controllerReady = Completer<InAppWebViewController>();

    /// 当前这次页面加载的完成信号（每次 loadUrl 前重建）。
    Completer<void>? pendingLoad;

    final headless = HeadlessInAppWebView(
      // 关键：默认 initialSize 是 Size.zero → window.innerWidth/Height 都是 0。
      // Cloudflare 等 bot 检测会看视口尺寸/渲染能力，零尺寸等于自报「我是 headless」，
      // 挑战永远过不去（表现为页面内 fetch 被拦）。这里给一个桌面视口。
      initialSize: const Size(1280, 800),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        // 复用系统 WebView 的 Cookie 池：用户之前登录过就直接带登录态，
        // 省掉一次 CDN 挑战。
        sharedCookiesEnabled: true,
        thirdPartyCookiesEnabled: true,
        userAgent: _kUserAgent,
        transparentBackground: true,
        isInspectable: false,
      ),
      onWebViewCreated: (controller) {
        if (!controllerReady.isCompleted) controllerReady.complete(controller);
      },
      onLoadStop: (controller, url) {
        final waiter = pendingLoad;
        if (waiter != null && !waiter.isCompleted) waiter.complete();
      },
      onReceivedError: (controller, request, error) {
        // 删掉预览后，「加载失败」只能靠日志留痕 —— 否则失败是纯黑盒
        state.pushLog('加载失败：${error.description} · ${request.url}');
      },
      onReceivedHttpError: (controller, request, response) {
        // 401/403/429 这类只能从 HTTP 状态码看出来，onReceivedError 收不到
        state.pushLog('HTTP ${response.statusCode} · ${request.url}');
      },
    );

    /// 加载指定 URL 并等 onLoadStop（超时也继续：挑战页可能已经渲染出内容）。
    ///
    /// [headers] 只给**直连 API** 那次用（`Accept: application/json`）：
    /// fallback 加载 `/search` 时不能带，否则服务器可能直接回 JSON，
    /// 页面脚本环境就没了，反而把挑战流程弄坏。
    Future<void> loadAndWait(
      InAppWebViewController controller,
      String url, {
      Map<String, String>? headers,
    }) async {
      final waiter = Completer<void>();
      pendingLoad = waiter;
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(url), headers: headers),
      );
      try {
        await waiter.future.timeout(_kLoadTimeout);
      } on TimeoutException {
        state.pushLog('加载超时（${_kLoadTimeout.inSeconds}s）：$url');
      }
    }

    /// 读响应/页面元信息，用于「直连没拿到 JSON」时的排障：
    /// contentType 区分 HTML/JSON，title 通常是挑战页标题（"Just a moment..."），
    /// 视口尺寸能直接验证 `initialSize` 是否生效（0×0 就是没生效）。
    Future<String> readDocMeta(InAppWebViewController controller) async {
      try {
        final raw = await controller.evaluateJavascript(
          source: 'JSON.stringify({'
              'contentType: document.contentType || "", '
              'title: (document.title || "").slice(0, 60), '
              'w: window.innerWidth, h: window.innerHeight})',
        );
        return raw is String ? raw : '$raw';
      } on Object catch (e) {
        return '（读取元信息失败：$e）';
      }
    }

    /// 读页面正文文本。直连 API 时这里就是原始 JSON。
    Future<String> readBody(InAppWebViewController controller) async {
      try {
        final raw = await controller.evaluateJavascript(
          source: 'document.body ? document.body.innerText : ""',
        );
        return (raw is String ? raw : '$raw').trim();
      } on Object catch (e) {
        state.pushLog('读取页面文本失败：$e');
        return '';
      }
    }

    try {
      // ① 启动：构造只登记参数，必须 run() 才会真正创建原生 WebView
      await headless.run();
      final controller =
          await controllerReady.future.timeout(_kHeadlessInitTimeout);

      // ② 路径一：直连 API
      if (mounted) setState(() => _diag = '直连 API…');
      state.pushLog('直连 API：$_apiUrl');
      try {
        // 带 Accept: application/json —— 不带时 Censys 可能回 HTML 外壳，
        // 页面内判定就会误判成「被挑战」。只加在这一次（见 loadAndWait 注释）。
        await loadAndWait(
          controller,
          _apiUrl,
          headers: const {'Accept': 'application/json, text/plain, */*'},
        );
      } on Object catch (e) {
        state.pushLog('直连加载异常：$e');
      }
      final directText = await readBody(controller);
      final direct = censysJsonOrNull(directText);
      if (direct != null) {
        _viaApi = true;
        return direct;
      }

      // 不是 JSON：把「拿到了什么」写进日志，否则无从判断是被挑战还是结构变了
      state.pushLog(
        '直连未拿到 JSON（${directText.length} 字节），开头：${_head(directText, 120)}',
      );
      state.pushLog('直连响应元信息：${await readDocMeta(controller)}');

      // ③ 路径二：加载搜索页过 CDN 挑战，再在页面内 fetch（带 Cookie）
      if (mounted) setState(() => _diag = '直连被拦截，加载页面过验证…');
      final viaPage = await _fetchViaPage(
        controller: controller,
        state: state,
        query: query,
        loadAndWait: loadAndWait,
        readBody: readBody,
      );
      if (viaPage == null) {
        state.pushLog('过验证后仍未拿到数据');
      } else {
        _viaApi = false;
      }
      return viaPage;
    } finally {
      // 必须 dispose：否则每次抓取泄漏一个原生 WebView
      try {
        await headless.dispose();
      } on Object catch (e) {
        state.pushLog('释放 headless WebView 失败：$e');
      }
    }
  }

  /// 路径二（fallback）：先加载 `/search` 过 CDN 挑战，再在页面内 fetch API。
  ///
  /// 为什么保留：直连在某些网络/风控下只会拿到挑战 HTML。页面内 fetch 带着
  /// 已通过的 Cookie（`credentials: include`），是绕过挑战的唯一方式。
  Future<String?> _fetchViaPage({
    required InAppWebViewController controller,
    required AppState state,
    required String query,
    required Future<void> Function(InAppWebViewController, String) loadAndWait,
    required Future<String> Function(InAppWebViewController) readBody,
  }) async {
    await loadAndWait(controller, '$_origin/search');

    final quoted = jsonEncode(query);
    final kick = '''
(function(){
  if (window.__cytestStarted) return "started";
  window.__cytestStarted = true;
  window.__cytestResult = null;
  window.__cytestError = null;
  fetch("$_searchPath?q=" + encodeURIComponent($quoted), {
    credentials: "include",
    headers: { "Accept": "application/json, text/plain, */*" }
  }).then(function(r){ return r.text(); })
    .then(function(t){ window.__cytestResult = t; })
    .catch(function(e){ window.__cytestError = String(e); });
  return "kicked";
})()
''';

    final probe = '''
(function(){
  if (window.__cytestError) return "err:" + window.__cytestError;
  if (window.__cytestResult !== null && window.__cytestResult !== undefined)
    return "ok:" + window.__cytestResult.length;
  return "wait";
})()
''';

    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted) return null;
      try {
        await controller.evaluateJavascript(source: kick);
        final raw = await controller.evaluateJavascript(source: probe);
        final text = raw is String ? raw : '$raw';
        if (text.startsWith('ok:')) {
          final got = await controller.evaluateJavascript(
              source: 'window.__cytestResult');
          final parsed = censysJsonOrNull(got is String ? got : '$got');
          if (parsed != null) return parsed;
        } else if (text.startsWith('err:')) {
          final reason = text.substring(4);
          state.pushLog('页面内 fetch 失败：$reason');
          if (mounted) setState(() => _error = '浏览器内请求失败：$reason');
          return null;
        }
        // 挑战通过后页面可能自己跳到了 API：每隔几轮直接读一次正文兜底
        if (i % 5 == 4) {
          final body = censysJsonOrNull(await readBody(controller));
          if (body != null) return body;
        }
      } on Object catch (e) {
        // 页面可能正在 reload（挑战），继续重试
        state.pushLog('注入脚本异常（重试中）：$e');
      }
    }
    return null;
  }

  /// 复制 API 链接到剪贴板。
  ///
  /// 原来这里是「浏览器打开」（靠可见 WebView 的 loadUrl）；换成 headless 后没有
  /// 界面可展示，而引入 `url_launcher` 需要新增依赖（已报 team-lead 决定），
  /// 先用复制链接兜住：用户粘到系统浏览器里过验证，再回来点「获取」。
  Future<void> _copyApiUrl() async {
    final url = _apiUrl;
    await Clipboard.setData(ClipboardData(text: url));
    _toast('已复制 API 链接，可在浏览器打开过验证');
  }

  /// 把当前拉到的 JSON 直接带进「本地测试」页。
  ///
  /// 旧实现是 `Navigator.pop(body)` 把 JSON 当返回值弹回去，但调用方从不 await，
  /// 返回值直接丢弃 —— 用户看到的就是「点一下就回首页、数据没了」。
  void _import() {
    final body = _payload;
    if (body == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TestPage(initialInput: body)),
    );
  }

  /// 从 Censys 响应里抠出前 [limit] 条 `ip:port`，用于结果摘要卡。
  ///
  /// 全程容错：`results` / `hits` 任意一层缺失或类型不对都只返回空列表，绝不抛异常。
  List<String> _parseHits(String json, {int limit = 5}) {
    final out = <String>[];
    try {
      final dynamic decoded = jsonDecode(json);
      if (decoded is! Map) return out;
      final dynamic results = decoded['results'];
      if (results is! Map) return out;
      final dynamic hits = results['hits'];
      if (hits is! List) return out;
      for (final dynamic hit in hits) {
        if (out.length >= limit) break;
        if (hit is! Map) continue;
        final dynamic host = hit['host'];
        if (host is! Map) continue;
        final dynamic ip = host['ip'];
        final dynamic port = host['port'];
        if (ip == null || port == null) continue;
        out.add('$ip:$port');
      }
    } catch (_) {
      return out;
    }
    return out;
  }

  /// 取 [s] 的前 [limit] 个 UTF-16 码元，不切断代理对（避免尾部半个字符）。
  String _head(String s, int limit) {
    if (s.length <= limit) return s;
    var end = limit;
    final unit = s.codeUnitAt(end - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF && end < s.length) end += 1;
    return '${s.substring(0, end)}…';
  }

  /// 整段原始 JSON 复制到剪贴板。
  Future<void> _copyPayload() async {
    final body = _payload;
    if (body == null) return;
    await Clipboard.setData(ClipboardData(text: body));
    _toast('已复制原始 JSON（${(body.length / 1024).toStringAsFixed(0)} KB）');
  }

  Future<void> _setProxy(int port) async {
    try {
      await ProxyController.instance().setProxyOverride(
        settings: ProxySettings(
          proxyRules: [ProxyRule(url: 'http://127.0.0.1:$port')],
        ),
      );
    } catch (_) {
      // 部分机型不支持全局覆盖，忽略
    }
  }

  Future<void> _clearProxy() async {
    try {
      await ProxyController.instance().clearProxyOverride();
    } catch (_) {}
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasLine = context.watch<AppState>().settings.vlessLinks.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('获取数据'),
        actions: [
          TextButton(
            onPressed: _fetching ? null : _copyApiUrl,
            child: const Text('复制 API 链接'),
          ),
          const SizedBox(width: 4),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: FilledButton(
              onPressed: _fetching ? null : _fetch,
              child: Text(_fetching ? '获取中…' : '获取'),
            ),
          ),
        ],
      ),
      // 保持可 resize：编辑查询语句时键盘不能盖住输入框。
      resizeToAvoidBottomInset: true,
      // 底部 SafeArea：body 不会自动避让系统手势条 / 三键导航。
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
          children: [
            Row(
              children: [
                _stat(theme, '命中总数', _hits > 0 ? '$_hits' : '—'),
                const SizedBox(width: 10),
                _stat(
                  theme,
                  '响应大小',
                  _bytes > 0 ? '${(_bytes / 1024).toStringAsFixed(0)} KB' : '—',
                ),
                const SizedBox(width: 10),
                _stat(theme, '耗时', _costMs > 0 ? '$_costMs ms' : '—'),
              ],
            ),
            const SizedBox(height: 14),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Censys 查询', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _cql,
                      maxLines: 5,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        // monospace 在 Android 上没有中文字形，缺 fallback 中文变方块
                        fontFamilyFallback: <String>['sans-serif'],
                        fontSize: 12.5,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => setState(() {
                            _cql.text =
                                Defaults.buildQuery(Defaults.fingerprint);
                          }),
                          child: const Text('恢复默认'),
                        ),
                        const Spacer(),
                        FilledButton.tonal(
                          onPressed: _payload == null ? null : _import,
                          child: const Text('导入到本地测试'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('状态', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    if (_error != null) ...[
                      Text(
                        _error!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          TextButton(
                            onPressed: _copyApiUrl,
                            child: const Text('复制 API 链接'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const TestPage(),
                              ),
                            ),
                            child: const Text('手动粘贴 JSON'),
                          ),
                        ],
                      ),
                      Text(
                        '可把复制的链接粘到系统浏览器里过验证，再回来点「获取」。',
                        style: theme.textTheme.labelSmall,
                      ),
                    ] else if (_payload != null)
                      Text('获取成功（$_diag），命中 $_hits 条，响应 $_bytes 字节。'
                          '点「导入到本地测试」开始跑三阶段。')
                    else
                      Text(
                        '$_diag'
                        '${_usedProxyPort != null ? " · 出站 Xray 127.0.0.1:$_usedProxyPort" : " · 直连"}'
                        '${hasLine ? "" : "\n未配置线路，国内网络直连 Censys 通常不可达，建议先去「线路与代理」填 VLESS"}',
                        style: TextStyle(
                          color: hasLine
                              ? theme.colorScheme.onSurfaceVariant
                              : theme.colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_payload != null) _payloadCard(theme),
          ],
        ),
      ),
    );
  }

  /// 结果摘要卡：一屏讲清「这次拉到了什么」。
  Widget _payloadCard(ThemeData theme) {
    final kb = (_bytes / 1024).toStringAsFixed(0);
    final sec = (_costMs / 1000).toStringAsFixed(1);
    final totalLabel = _hits > 0 ? '$_hits' : '${_previewTargets.length}';
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('预览', style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '命中 $totalLabel 条 · $kb KB · $sec s',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_previewTargets.isEmpty)
              Text(
                _previewRaw.isEmpty ? '（没有可展示的内容）' : _previewRaw,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontFamilyFallback: <String>['sans-serif'],
                  fontSize: 11,
                ),
              )
            else ...[
              ..._previewTargets.asMap().entries.map(
                    (e) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '${e.key + 1}. ${e.value}',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontFamilyFallback: <String>['sans-serif'],
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
              const SizedBox(height: 2),
              Text(
                '共 $totalLabel 条候选，这里只列前 ${_previewTargets.length} 条',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _copyPayload,
                icon: const Icon(Icons.copy_all_outlined, size: 16),
                label: const Text('复制原始 JSON'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(ThemeData theme, String label, String value) => Expanded(
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelSmall),
                const SizedBox(height: 2),
                Text(value, style: theme.textTheme.titleMedium),
              ],
            ),
          ),
        ),
      );
}

/// 判定「这段文本是不是 Censys 搜索结果」。
///
/// 直连 `/api/search` 时，WebView 的 `document.body.innerText` 有两种可能：
/// 1. 真数据：一段 JSON 对象，含 `results` 字段 → 返回原文（两侧空白已 trim）；
/// 2. 被 CDN 挑战拦截：HTML 页面、空内容，或 JSON 但不是搜索结果（错误响应）。
///    这几种一律返回 null，交给调用方走「加载页面过验证」的 fallback。
///
/// 为什么单独抽成顶层函数：这是「直连 vs fallback」的唯一判据，也是最容易写错的
/// 地方（例如把 HTML 当数据、或忘了校验 `results`），抽出来才能脱离 WebView 单测。
String? censysJsonOrNull(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || !trimmed.startsWith('{')) return null;
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map && decoded['results'] != null) return trimmed;
  } on Object {
    return null;
  }
  return null;
}
