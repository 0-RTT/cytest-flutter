import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../../core/settings.dart';
import '../../data/history.dart';
import '../../state/app_state.dart';
import 'test_page.dart';

/// 获取数据：用系统 WebView 过 CDN 挑战，再在页面内 fetch /api/search。
/// 与 Android 端 CensysFetcher / 桌面端爬取链路同构。
class FetchPage extends StatefulWidget {
  const FetchPage({super.key});

  @override
  State<FetchPage> createState() => _FetchPageState();
}

class _FetchPageState extends State<FetchPage> {
  static const _origin = 'https://platform.censys.io';
  static const _searchPath = '/api/search';

  /// WebView 首次创建的最长等待时间。
  /// 低端机首次创建 PlatformView 经常超过 3 秒，3 秒就判失败是误杀。
  static const _kWebInitTimeout = Duration(seconds: 15);

  /// 预览面板高度上限。必须是真实可见区域，PlatformView 才会被创建。
  /// 120 而非 180：用户反馈 180 太占地，而整页缩放（见 useWideViewPort /
  /// loadWithOverviewMode）之后，120 已足够看清挑战页的版面结构，
  /// 真想细看还有「放大」档（屏高 55%）。
  static const _kPreviewMaxHeight = 120.0;

  /// 预览面板「折叠档」的高度下限，同时是键盘弹出时的面板高度。
  /// 绝对不能压到 0 或移出屏外——那会让 PlatformView 被销毁、`_web` 置空、
  /// 正在跑的 loadUrl 丢失，正好又踩回「onWebViewCreated 不触发」的老坑。
  /// 键盘态只占 60 也不会出现「一条缝」：那时标题行整行不渲染（见 _previewPanel），
  /// 面板固定开销只剩 margin 6 + 描边 2，网页仍有 52 高。
  static const _kPreviewMinHeight = 60.0;

  /// 预览面板占屏高的比例，用于横屏/小屏时收窄。
  static const _kPreviewScreenRatio = 0.28;

  /// 用户点「放大」后预览区占屏高的比例。
  /// 窄条只露出网页一小片，看不清验证码/挑战页，所以给一个接近半屏的档位。
  static const _kPreviewLargeRatio = 0.55;

  /// 放大后仍要留给上方表单的最小高度。
  /// 否则大屏上预览会把查询输入框整个挤出去，用户没法边改语句边看预览。
  static const _kPreviewMinFormSpace = 200.0;

  /// 高度切换动画时长。只改父级容器的高度，WebView 元素不搬家；
  /// 200ms 以内，避免拖慢首帧。
  static const _kPreviewAnimDuration = Duration(milliseconds: 180);

  late final TextEditingController _cql =
      TextEditingController(text: Defaults.buildQuery(Defaults.fingerprint));

  InAppWebViewController? _web;
  Timer? _poll;
  Completer<void>? _loadWaiter;

  bool _fetching = false;

  /// 预览区是否处于「放大」档位。只影响父级高度，不影响 WebView 位置。
  bool _previewExpanded = false;

  String _diag = 'WebView 初始化中…';
  int? _usedProxyPort;
  String? _error;

  /// 最近一次 onReceivedError 的描述（含失败 URL），失败时原样显示给用户。
  String? _lastError;
  String? _payload;
  int _hits = 0;
  int _bytes = 0;
  int _costMs = 0;

  /// 预览卡里展示的前几条 ip:port，在 _fetch 成功时解析一次并缓存。
  /// 不能放在 build 里解析：响应有几百 KB，每次 setState 都 jsonDecode 会明显掉帧。
  List<String> _previewTargets = const [];

  /// 解析不出 hits 时的兜底展示（原始 JSON 前 200 字符），同样在 _fetch 时算好。
  String _previewRaw = '';

  @override
  void dispose() {
    _poll?.cancel();
    _cql.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    final query = _cql.text.trim();
    if (query.isEmpty) {
      _toast('查询语句不能为空');
      return;
    }

    // 测速期间必须拒绝：下面「线路没跑就先 startLine()」会走 XrayProc.start()，
    // 而 start() 首行是 stop() —— 会把正在跑的批量测速进程直接杀掉，
    // 用户完全看不出发生了什么。这里只拦这一个条件，其余抓取链路不动。
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
    });

    final state = context.read<AppState>();
    final started = DateTime.now();

    // 有线路就先起 Xray，抓取走它的本地端口（与 App 的 fetchViaProxy 等价）
    int? proxyPort;
    try {
      if (state.settings.vlessLinks.isNotEmpty) {
        if (!state.xray.running) {
          await state.startLine();
        }
        if (state.xray.running) proxyPort = state.xray.port;
      }
    } catch (e) {
      // 线路起不来不阻塞直连尝试
      state.pushLog('线路未启动：$e');
    }

    _usedProxyPort = proxyPort;
    if (proxyPort != null) {
      await _setProxy(proxyPort);
    } else {
      await _clearProxy();
    }

    // 首次进入页面时 WebView 可能还没 attach。低端机创建 PlatformView 常超过
    // 3 秒，这里等最多 15 秒，并把已等秒数显示出来，避免用户误以为卡死。
    final webStart = DateTime.now();
    while (_web == null &&
        DateTime.now().difference(webStart) < _kWebInitTimeout) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      if (_web == null) {
        final waited = DateTime.now().difference(webStart).inSeconds;
        setState(() => _diag = 'WebView 创建中…（已等 $waited 秒）');
      }
    }
    final web = _web;
    if (web == null) {
      setState(() {
        _fetching = false;
        _error = _webInitFailure();
      });
      return;
    }

    _loadWaiter = Completer<void>();
    await web.loadUrl(urlRequest: URLRequest(url: WebUri('$_origin/search')));

    // 等页面加载完（onLoadStop），或超时
    try {
      await _loadWaiter!.future.timeout(const Duration(seconds: 25));
    } catch (_) {
      // 超时继续，挑战可能仍在进行
    }

    // 注入轮询脚本，与桌面端一致：页面内发起 fetch，结果写全局变量
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

    String? body;
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 900));
      try {
        await web.evaluateJavascript(source: kick);
        final raw = await web.evaluateJavascript(source: probe);
        final text = raw?.toString() ?? '';
        if (text.startsWith('ok:')) {
          final got =
              await web.evaluateJavascript(source: 'window.__cytestResult');
          final str = got?.toString() ?? '';
          if (str.startsWith('{') && str.endsWith('}')) {
            body = str;
            break;
          }
        } else if (text.startsWith('err:')) {
          setState(() {
            _fetching = false;
            _error = '浏览器内请求失败：${text.substring(4)}';
          });
          await _clearProxy();
          return;
        }
      } catch (_) {
        // 页面可能正在 reload（挑战），继续重试
      }
    }

    await _clearProxy();

    if (body == null) {
      setState(() {
        _fetching = false;
        _error = '30 秒内没有拿到数据，可能挑战未通过。可点「浏览器打开」手动过一次验证';
      });
      return;
    }

    var hits = 0;
    try {
      final obj = jsonDecode(body) as Map<String, dynamic>;
      final results = obj['results'] as Map<String, dynamic>?;
      hits = (results?['total_hits'] as num?)?.toInt() ?? 0;
    } catch (_) {}

    // 预览卡要给人看「拉到了什么」，而不是几百 KB 裸 JSON。
    // 解析一次即缓存，容错到任何字段缺失都不抛异常。
    final targets = _parseHits(body);
    final rawHead = _head(body, 200);

    await state.saveArchive(body);

    setState(() {
      _fetching = false;
      _payload = body;
      _hits = hits;
      _bytes = body!.length;
      _costMs = DateTime.now().difference(started).inMilliseconds;
      _previewTargets = targets;
      _previewRaw = rawHead;
    });
    _toast('获取成功：$hits 条');
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

  /// WebView 创建失败的具体原因：优先给出最近一次真实的加载错误。
  String _webInitFailure() {
    final last = _lastError;
    if (last != null && last.isNotEmpty) {
      return 'WebView 创建失败：${_kWebInitTimeout.inSeconds} 秒内没有完成初始化。\n'
          '最近一次加载错误：$last';
    }
    return 'WebView 创建失败：${_kWebInitTimeout.inSeconds} 秒内没有收到 onWebViewCreated。\n'
        '排查建议：设置 → 应用 → Android System WebView（或 Chrome）→ 启用并更新；'
        '若已被禁用或卸载，页面无法加载任何内容。';
  }

  Future<void> _openInBrowser() async {
    final web = _web;
    if (web == null) return;
    // 让用户看到真实页面并手动过验证；成功后关闭返回
    await web.loadUrl(urlRequest: URLRequest(url: WebUri('$_origin/search')));
    _toast('如出现验证，请完成后再点「获取」');
  }

  /// 从 Censys 响应里抠出前 [limit] 条 `ip:port`，用于预览卡摘要。
  ///
  /// 全程容错：`results` / `hits` 任意一层缺失或类型不对都只返回空列表，
  /// 绝不抛异常（接口出错时拿到的可能是错误页 HTML 或半截 JSON）。
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
      // 不是合法 JSON（错误页、被截断的响应）：交给调用方退回原文展示
      return out;
    }
    return out;
  }

  /// 取 [s] 的前 [limit] 个 UTF-16 码元，且不把代理对（emoji 等）从中间切断，
  /// 否则尾部会出现半个字符（渲染成「�」）。
  String _head(String s, int limit) {
    if (s.length <= limit) return s;
    var end = limit;
    final unit = s.codeUnitAt(end - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF && end < s.length) end += 1;
    return '${s.substring(0, end)}…';
  }

  /// 整段原始 JSON 复制到剪贴板。之前预览只是一段不可选的 Text，用户想复制
  /// 去别处分析/求助时无从下手，所以给一个显式按钮。
  Future<void> _copyPayload() async {
    final body = _payload;
    if (body == null) return;
    await Clipboard.setData(ClipboardData(text: body));
    _toast('已复制原始 JSON（${(body.length / 1024).toStringAsFixed(0)} KB）');
  }

  /// 把当前拉到的 JSON 直接带进「本地测试」页。
  ///
  /// 旧实现是 `Navigator.pop(body)` 把 JSON 当返回值弹回去，但调用方
  /// （home.dart 的 `_push(context, const FetchPage())`）从来不 await，
  /// 返回值直接丢弃 —— 用户看到的就是「点一下就回首页、数据没了」。
  /// 改成主动 push：不依赖返回值，push 返回后本页状态（含 _payload 与预览）
  /// 完整保留，用户从测试页返回还能接着看。
  /// 传的是完整 JSON：三阶段漏斗需要原始 Censys 结构，只给 ip:port 列表会丢信息。
  void _import() {
    final body = _payload;
    if (body == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TestPage(initialInput: body)),
    );
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

    // 预览区高度：
    // - 键盘弹出时压到 60（标题行整行隐藏，网页实际可见 52；PlatformView 不会被销毁）；
    // - 平时取 min(120, 屏高 * 28%)，横屏/小屏不至于挤掉一半内容，且不低于 60；
    // - 「放大」档取 屏高 * 55%，但必须给上方表单留出至少 200 的空间。
    // 注意：这里必须用 build 的 context（在 Scaffold 之上）读 viewInsets——
    // Scaffold 在 resizeToAvoidBottomInset: true 时会把 body 的 viewInsets 底部抹成 0，
    // 一旦把这段判断挪进 body 内部就会永远读到 0。
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final collapsedHeight = (screenHeight * _kPreviewScreenRatio)
        .clamp(_kPreviewMinHeight, _kPreviewMaxHeight)
        .toDouble();
    // 这里用 if 而不是 clamp：极小屏（如横屏 250 高）时下界可能大于上界，
    // clamp 会直接抛断言，宁可退化成 collapsedHeight。
    var largeHeight = screenHeight * _kPreviewLargeRatio;
    final largeUpperBound = screenHeight - _kPreviewMinFormSpace;
    if (largeHeight > largeUpperBound) largeHeight = largeUpperBound;
    if (largeHeight < collapsedHeight) largeHeight = collapsedHeight;
    final previewHeight = keyboardUp
        ? _kPreviewMinHeight
        : (_previewExpanded ? largeHeight : collapsedHeight);

    return Scaffold(
      appBar: AppBar(
        title: const Text('获取数据'),
        actions: [
          TextButton(
              onPressed: _fetching ? null : _openInBrowser,
              child: const Text('浏览器打开')),
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
      // 键盘占掉的高度由预览区（压到 60）和可滚动的 ListView 吸收。
      resizeToAvoidBottomInset: true,
      // 底部 SafeArea：Scaffold 的 body 不会自动避让系统手势条 / 三键导航，
      // 不包这层，底部预览区会被系统栏压住（用户实测「底部显示不完整」）。
      // top: false —— 顶部已由 AppBar 处理，否则会多出一截空白。
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                // 底部 24 是纯视觉呼吸：系统手势条已由外层 SafeArea 避让。
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                children: [
                  Row(
                    children: [
                      _stat(theme, '命中总数', _hits > 0 ? '$_hits' : '—'),
                      const SizedBox(width: 10),
                      _stat(
                          theme,
                          '响应大小',
                          _bytes > 0
                              ? '${(_bytes / 1024).toStringAsFixed(0)} KB'
                              : '—'),
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
                              fontFamilyFallback: ['sans-serif'],
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
                            Text(_error!,
                                style:
                                    TextStyle(color: theme.colorScheme.error)),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                TextButton(
                                  onPressed: _openInBrowser,
                                  child: const Text('浏览器打开'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                        builder: (_) => const TestPage()),
                                  ),
                                  child: const Text('手动粘贴 JSON'),
                                ),
                              ],
                            ),
                            Text(
                              '在浏览器里完成验证后，把搜索结果 JSON 复制到「本地测试」页即可。',
                              style: theme.textTheme.labelSmall,
                            ),
                          ] else if (_web == null)
                            Text(_diag,
                                style: TextStyle(
                                    color: theme.colorScheme.onSurfaceVariant))
                          else if (_payload != null)
                            Text(
                                '获取成功，命中 $_hits 条，响应 $_bytes 字节。点「导入到本地测试」开始跑三阶段。')
                          else
                            Text(
                              '$_diag · 出站 ${_usedProxyPort != null ? "Xray 127.0.0.1:$_usedProxyPort" : "直连"}'
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
            // 预览面板必须放在真实可见的位置，Flutter 才会真正创建 PlatformView。
            // 之前用过 SizedBox(height:1) / Positioned(left:-3000) / Opacity(0.01)，
            // 三种写法都会导致 onWebViewCreated 不触发，于是「WebView 初始化失败」。
            // 放大/收起只改这里的高度，`_previewPanel` 在树里的位置完全不变——
            // 元素类型与层级一致，Flutter 会复用同一个 Element，PlatformView 不会被重建。
            AnimatedContainer(
              duration: _kPreviewAnimDuration,
              curve: Curves.easeOut,
              height: previewHeight,
              child: _previewPanel(theme, keyboardUp),
            ),
          ],
        ),
      ),
    );
  }

  /// 底部 WebView 预览区：可见即可创建，同时让用户直接看到挑战页进度。
  ///
  /// [keyboardUp] 为真时**只**跳过标题行（文案 + 放大按钮），WebView 本身照旧常驻：
  /// 面板只有 60 高，标题行要占 38，不隐藏的话网页只剩 14 高、看着像坏了。
  /// 注意条件只能包标题行，绝不能包到 Expanded/WebView 外面——那样改的是 WebView
  /// 的父链结构，PlatformView 会被重建，直接复发「WebView 初始化失败」。
  Widget _previewPanel(ThemeData theme, bool keyboardUp) {
    final ready = _web != null;
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!keyboardUp)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 6, 2),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      // 说清这块是干什么的：用户之前不知道预览窗口的用途
                      '页面预览（过验证用，可放大）',
                      style: theme.textTheme.labelMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    ready ? '已就绪' : '未就绪',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: ready
                          ? theme.colorScheme.primary
                          : theme.colorScheme.error,
                    ),
                  ),
                  const SizedBox(width: 2),
                  // 只在两个高度档位之间切换；WebView 本身不动，避免 PlatformView 重建。
                  // 尺寸必须走 style：M3 主题下 IconButton 的 iconSize / padding /
                  // visualDensity / constraints 四个构造参数会被 _IconButtonM3 丢掉，
                  // 默认 tapTargetSize: padded 还会把按钮撑到 40，标题行跟着涨到 46，
                  // 直接从网页可见高度里抢走 ~14px（实测 40→32、标题行 46→38）。
                  IconButton(
                    onPressed: () =>
                        setState(() => _previewExpanded = !_previewExpanded),
                    style: IconButton.styleFrom(
                      iconSize: 18,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(32, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    tooltip: _previewExpanded ? '收起预览' : '放大预览',
                    icon: Icon(
                      _previewExpanded ? Icons.unfold_less : Icons.unfold_more,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            // 套一层描边容器：预览区不高，网页和页面底色容易糊成一片，
            // 有边界用户才知道这块是嵌进来的网页。
            child: Container(
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: InAppWebView(
                // 这五项是「像浏览器那样整页显示」的关键，缺一个就会退化成 1:1
                // 原尺寸渲染：桌面版 Censys 页面按 1024/1280 布局，塞进 120px 高的
                // 窄条里只能看到左上角一小块，文字巨大且溢出——用户口中的「乱码」
                // 就是这种放大看局部的效果，并不是编码问题。
                // - useWideViewPort + loadWithOverviewMode：按页面 viewport 宽度
                //   等比缩放到容器内，看到的是整页缩略全景；
                // - supportZoom + builtInZoomControls：保留双指缩放，方便看清验证码；
                // - displayZoomControls: false：隐藏老式的 +/- 悬浮按钮（丑且挡内容）。
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  thirdPartyCookiesEnabled: true,
                  sharedCookiesEnabled: true,
                  transparentBackground: true,
                  isInspectable: false,
                  useWideViewPort: true,
                  loadWithOverviewMode: true,
                  supportZoom: true,
                  builtInZoomControls: true,
                  displayZoomControls: false,
                ),
                onWebViewCreated: (c) {
                  _web = c;
                  if (mounted) setState(() => _diag = 'WebView 已创建');
                },
                onLoadStart: (c, url) {
                  if (mounted) setState(() => _diag = '加载 ${url?.host ?? ''}…');
                },
                onLoadStop: (c, url) {
                  if (mounted) setState(() => _diag = '页面加载完成');
                  final w = _loadWaiter;
                  if (w != null && !w.isCompleted) w.complete();
                },
                onReceivedError: (c, req, err) {
                  // 主文档的错误最有诊断价值，子资源错误不覆盖它
                  if (req.isForMainFrame == false && _lastError != null) return;
                  final text = '${err.description}（${req.url}）';
                  if (mounted) {
                    setState(() {
                      _lastError = text;
                      _diag = '加载错误：$text';
                    });
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 预览卡：一屏讲清「这次拉到了什么」。
  ///
  /// 旧版直接把 `_payload` 前 500 字符当 Text 甩出来：几百 KB 的 JSON 被硬切成
  /// 半截、不可选不可复制，用户看到的就是一堆乱码般的括号引号。
  /// 现在改成「一行摘要 + 前 5 条 ip:port + 复制原始 JSON」——
  /// 摘要回答体量与耗时，ip:port 回答内容，复制按钮保留原始数据的可用性。
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
              // 解析不出 hits（错误页 / 结构变动）：退回展示原始文本开头，
              // 让用户仍能判断拿到的是不是想要的东西。
              Text(
                _previewRaw.isEmpty ? '（没有可展示的内容）' : _previewRaw,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  // Android 的 monospace 族不含完整中文字形，缺 fallback 中文会显示成方块
                  fontFamilyFallback: ['sans-serif'],
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
                          fontFamilyFallback: ['sans-serif'],
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
