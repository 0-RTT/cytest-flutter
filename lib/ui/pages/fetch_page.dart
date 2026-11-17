import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
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
  static const _kPreviewMaxHeight = 180.0;

  /// 预览面板高度下限：键盘弹出时压到这个高度。
  /// 绝对不能压到 0 或移出屏外——那会让 PlatformView 被销毁、`_web` 置空、
  /// 正在跑的 loadUrl 丢失，正好又踩回「onWebViewCreated 不触发」的老坑。
  static const _kPreviewMinHeight = 60.0;

  /// 预览面板占屏高的比例，用于横屏/小屏时收窄。
  static const _kPreviewScreenRatio = 0.28;

  late final TextEditingController _cql =
      TextEditingController(text: Defaults.buildQuery(Defaults.fingerprint));

  InAppWebViewController? _web;
  Timer? _poll;
  Completer<void>? _loadWaiter;

  bool _fetching = false;
  String _diag = 'WebView 初始化中…';
  int? _usedProxyPort;
  String? _error;

  /// 最近一次 onReceivedError 的描述（含失败 URL），失败时原样显示给用户。
  String? _lastError;
  String? _payload;
  int _hits = 0;
  int _bytes = 0;
  int _costMs = 0;

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

    setState(() {
      _fetching = true;
      _error = null;
      _payload = null;
      _hits = 0;
      _bytes = 0;
      _costMs = 0;
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
          final got = await web.evaluateJavascript(source: 'window.__cytestResult');
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

    await state.saveArchive(body);

    setState(() {
      _fetching = false;
      _payload = body;
      _hits = hits;
      _bytes = body!.length;
      _costMs = DateTime.now().difference(started).inMilliseconds;
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

  void _import() {
    final body = _payload;
    if (body == null) return;
    Navigator.of(context).pop(body);
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
    // - 键盘弹出时压到 60（仍可见，PlatformView 不会被销毁；键盘也不会把预览挤成 0 高度）；
    // - 平时取 min(180, 屏高 * 28%)，横屏/小屏不至于挤掉一半内容，且不低于 60。
    // 注意：这里必须用 build 的 context（在 Scaffold 之上）读 viewInsets——
    // Scaffold 在 resizeToAvoidBottomInset: true 时会把 body 的 viewInsets 底部抹成 0，
    // 一旦把这段判断挪进 body 内部就会永远读到 0。
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final previewHeight = keyboardUp
        ? _kPreviewMinHeight
        : (screenHeight * _kPreviewScreenRatio)
            .clamp(_kPreviewMinHeight, _kPreviewMaxHeight)
            .toDouble();

    return Scaffold(
      appBar: AppBar(
        title: const Text('获取数据'),
        actions: [
          TextButton(onPressed: _fetching ? null : _openInBrowser, child: const Text('浏览器打开')),
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
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(14),
              children: [
                Row(
                  children: [
                    _stat(theme, '命中总数', _hits > 0 ? '$_hits' : '—'),
                    const SizedBox(width: 10),
                    _stat(theme, '响应大小', _bytes > 0 ? '${(_bytes / 1024).toStringAsFixed(0)} KB' : '—'),
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
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
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
                                _cql.text = Defaults.buildQuery(Defaults.fingerprint);
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
                          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              TextButton(
                                onPressed: _openInBrowser,
                                child: const Text('浏览器打开'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => const TestPage()),
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
                          Text(_diag, style: TextStyle(color: theme.colorScheme.onSurfaceVariant))
                        else if (_payload != null)
                          Text('获取成功，命中 $_hits 条，响应 $_bytes 字节。点「导入到本地测试」开始跑三阶段。')
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
                if (_payload != null)
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('预览', style: theme.textTheme.titleSmall),
                          const SizedBox(height: 6),
                          Text(
                            _payload!.length > 500 ? '${_payload!.substring(0, 500)}…' : _payload!,
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 预览面板必须放在真实可见的位置，Flutter 才会真正创建 PlatformView。
          // 之前用过 SizedBox(height:1) / Positioned(left:-3000) / Opacity(0.01)，
          // 三种写法都会导致 onWebViewCreated 不触发，于是「WebView 初始化失败」。
          SizedBox(
            height: previewHeight,
            child: _previewPanel(theme),
          ),
        ],
      ),
    );
  }

  /// 底部 WebView 预览区：可见即可创建，同时让用户直接看到挑战页进度。
  Widget _previewPanel(ThemeData theme) {
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
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    '页面预览（过验证用）',
                    style: theme.textTheme.labelMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  ready ? '已就绪' : '未就绪',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: ready
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                thirdPartyCookiesEnabled: true,
                sharedCookiesEnabled: true,
                transparentBackground: true,
                isInspectable: false,
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
        ],
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
