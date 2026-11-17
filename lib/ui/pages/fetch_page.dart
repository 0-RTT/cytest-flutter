import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../../core/settings.dart';
import '../../data/history.dart';
import '../../state/app_state.dart';

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

  late final TextEditingController _cql =
      TextEditingController(text: Defaults.buildQuery(Defaults.fingerprint));

  InAppWebViewController? _web;
  Timer? _poll;
  Completer<void>? _loadWaiter;

  bool _fetching = false;
  String? _error;
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

    if (proxyPort != null) {
      await _setProxy(proxyPort);
    } else {
      await _clearProxy();
    }

    final web = _web;
    if (web == null) {
      setState(() {
        _fetching = false;
        _error = 'WebView 尚未就绪';
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
                        if (_error != null)
                          Text(_error!, style: TextStyle(color: theme.colorScheme.error))
                        else if (_payload != null)
                          Text('获取成功，命中 $_hits 条，响应 $_bytes 字节。点「导入到本地测试」开始跑三阶段。')
                        else
                          Text(
                            '点右上「获取」从 Censys 拉取。有线路时会经 Xray 出站，否则直连。',
                            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
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
          // 不可见的 WebView 承载挑战与请求
          SizedBox(
            height: 1,
            child: InAppWebView(
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                thirdPartyCookiesEnabled: true,
                sharedCookiesEnabled: true,
                transparentBackground: true,
                isInspectable: false,
              ),
              onWebViewCreated: (c) => _web = c,
              onLoadStop: (c, url) {
                final w = _loadWaiter;
                if (w != null && !w.isCompleted) w.complete();
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
