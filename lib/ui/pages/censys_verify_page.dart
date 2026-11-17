import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../data/censys_http.dart';

/// 验证页的返回值。
class CensysVerifyResult {
  const CensysVerifyResult({this.json, this.cookie = ''});

  /// 页面上直接读到的 JSON（挑战通过后页面可能自己跳到了 API）。
  final String? json;

  /// 从 WebView Cookie 池取到的 `Cookie:` 头值；空串 = 没取到。
  final String cookie;
}

/// 按需出现的**全屏**人机验证页。
///
/// 为什么必须是全屏可见的 `InAppWebView`：Cloudflare 的挑战要求真实渲染与可见性，
/// headless（零尺寸）会被判定为机器人，验证永远过不去（实测：API 返回
/// HTTP 200 + 3KB 挑战页，且该页 CSP 挡掉注入的 `fetch`）。
///
/// 这一页只在「纯 HTTP 拿不到 JSON」时出现；过完一次后 Cookie 存进设置，
/// 后续抓取不再需要它 —— 所以它不是「常驻预览」，主页仍然没有任何 WebView。
class CensysVerifyPage extends StatefulWidget {
  const CensysVerifyPage({
    super.key,
    required this.apiUrl,
    this.userAgent = kCensysUserAgent,
  });

  /// 要加载的地址（直连 API 或搜索页）。
  final String apiUrl;

  final String userAgent;

  @override
  State<CensysVerifyPage> createState() => _CensysVerifyPageState();
}

class _CensysVerifyPageState extends State<CensysVerifyPage> {
  static const _kPollInterval = Duration(milliseconds: 1200);

  /// 最多轮询多少次（≈2 分钟）；超时后不自动关闭，用户仍可点「完成」。
  static const _kMaxPolls = 100;

  InAppWebViewController? _controller;
  Timer? _poll;
  int _polls = 0;
  bool _finishing = false;
  bool _autoDone = false;
  String _status = '页面加载中…';

  @override
  void dispose() {
    _poll?.cancel();
    _poll = null;
    super.dispose();
  }

  void _startPolling() {
    _poll?.cancel();
    _polls = 0;
    _poll = Timer.periodic(_kPollInterval, (timer) async {
      if (_finishing) {
        timer.cancel();
        return;
      }
      _polls++;
      if (_polls > _kMaxPolls) {
        timer.cancel();
        if (mounted) setState(() => _status = '等待时间较长，可完成后重试；或点「完成」');
        return;
      }
      final json = await _readJson();
      if (json != null && !_finishing) {
        _autoDone = true;
        if (mounted) setState(() => _status = '已拿到数据，正在返回…');
        await _finish(json: json);
      }
    });
  }

  /// 读页面正文并判定是不是 Censys 搜索结果。
  Future<String?> _readJson() async {
    try {
      final raw = await _controller?.evaluateJavascript(
        source: 'document.body ? document.body.innerText : ""',
      );
      final text = raw is String ? raw : '${raw ?? ''}';
      return censysJsonOrNull(text);
    } on Object {
      return null; // 页面正在跳转/重载，下一轮再试
    }
  }

  /// 收 Cookie：先用 CookieManager（能拿到 HttpOnly 的），
  /// 不行再退回 `document.cookie`（拿不到 HttpOnly，但挑战 cookie 一般不设该属性）。
  Future<String> _collectCookie() async {
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri(kCensysOrigin),
        webViewController: _controller,
      );
      final header = buildCookieHeader(cookies);
      if (header.isNotEmpty) return header;
    } on Object {
      // 忽略，走 JS 兜底
    }
    try {
      final raw = await _controller?.evaluateJavascript(
        source: 'document.cookie',
      );
      return normalizeDocumentCookie(raw is String ? raw : '${raw ?? ''}');
    } on Object {
      return '';
    }
  }

  /// 结束并返回结果（[json] 为空表示「只拿到了 Cookie」）。
  Future<void> _finish({String? json}) async {
    if (_finishing) return;
    _finishing = true;
    _poll?.cancel();
    _poll = null;
    final cookie = await _collectCookie();
    if (!mounted) return;
    Navigator.of(context).pop(CensysVerifyResult(json: json, cookie: cookie));
  }

  /// 「完成」按钮：先尽力读一次数据，读不到就只把 Cookie 带回去（调用方重试 HTTP）。
  Future<void> _finishManually() async {
    if (_finishing) return;
    if (mounted) setState(() => _status = '正在收尾…');
    final json = await _readJson();
    await _finish(json: json);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Censys 人机验证'),
        actions: [
          TextButton(
            onPressed: _finishing ? null : _finishManually,
            child: const Text('完成'),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: theme.colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Censys 需要人机验证',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  '页面会自动完成验证；如需手动点击请按页面提示操作。'
                  '验证通过后点右上角「完成」，之后抓取会复用这次拿到的 Cookie。',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  _status,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _autoDone
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          // 必须是真实可见尺寸（Expanded 铺满）：可见性本身就是通过挑战的前提，
          // 不要改成 0 高度/Offstage/Opacity —— 那等于又变成 headless。
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.apiUrl)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                sharedCookiesEnabled: true,
                thirdPartyCookiesEnabled: true,
                userAgent: widget.userAgent,
                useWideViewPort: true,
                loadWithOverviewMode: true,
              ),
              onWebViewCreated: (controller) => _controller = controller,
              onLoadStop: (controller, url) {
                if (!mounted || _finishing) return;
                setState(() => _status = '页面已加载，正在检测验证状态…');
                _startPolling();
              },
              onProgressChanged: (controller, progress) {
                if (progress == 100 && !_finishing) _startPolling();
              },
            ),
          ),
        ],
      ),
    );
  }
}
