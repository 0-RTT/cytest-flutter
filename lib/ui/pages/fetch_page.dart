import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../../core/settings.dart';
import '../../data/censys_http.dart';
import '../../data/vless.dart';
import '../../state/app_state.dart';
import 'censys_verify_page.dart';
import 'test_page.dart';

/// 获取数据：**纯 HTTP 优先，必要时才开一次全屏验证页**。
///
/// 实测结论（决定了整个设计）：
/// - Censys 对未认证请求返回 **HTTP 200 + ~3KB 挑战页 HTML**（带严格 CSP
///   `default-src 'self'`），既不是 403 也不是 JSON；
/// - 该 CSP 会挡掉注入的 `fetch`，所以在 headless WebView 里执行
///   `fetch('/api/search')` 必然得到 `TypeError: Failed to fetch`；
/// - 因此 **WebView 只能用来过一次人机验证换 Cookie**，数据请求走 `HttpClient`
///   （`lib/data/censys_http.dart`，带 Cookie + 完整浏览器头）。
///
/// 本页自身**没有任何 WebView**：验证页是独立的按需全屏路由
/// （`lib/ui/pages/censys_verify_page.dart`）。
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

  bool _fetching = false;

  /// 状态串：当前在做什么 / 走的是哪条路径。
  /// 删掉预览之后，这是用户与排障者唯一的可观测信息。
  String _diag = '待命';

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

    // ① 纯 HTTP：带上次验证得到的 Cookie，走 Xray 本地端口。
    //    实测 Censys 对未认证请求返回「HTTP 200 + 挑战页 HTML」，且该页 CSP
    //    (`default-src 'self'`) 会挡掉注入的 fetch —— 所以 WebView 只用来换 Cookie，
    //    真正的数据请求交给 HttpClient（见 data/censys_http.dart 的注释）。
    final hasLine = state.settings.vlessLinks.isNotEmpty;
    final candidates = hasLine ? state.orderedProxyPool : const <ProxyIp>[];
    final attempts = candidates.isEmpty
        ? const <ProxyIp?>[null] // 没有 proxyip：链接原样，只试一次
        : candidates.map<ProxyIp?>((item) => item).toList(growable: false);

    String? body;
    String? lastError;
    var viaVerify = false;
    var usedCookie = state.settings.censysCookie.isNotEmpty;

    for (final proxy in attempts) {
      final port = await _startProxy(state, proxy, hasLine);
      if (hasLine && port == null) {
        await state.recordProxyResult(proxy, false);
        continue;
      }
      final result = await fetchCensysJson(
        query: query,
        cookie: state.settings.censysCookie,
        proxyPort: port,
      );
      await _clearProxy();
      if (result.ok) {
        body = result.json;
        _usedProxy = proxy?.key;
        await state.recordProxyResult(proxy, true);
        break;
      }
      lastError = result.error;
      state.pushLog(
        '纯 HTTP 未拿到 JSON（proxyip=${proxy?.key ?? "原样"}）：${result.error}'
        '｜Content-Type ${result.contentType}｜开头：${result.head}',
      );
      await state.recordProxyResult(proxy, false);
      if (!mounted) break;
    }

    // ② 仍然没有数据 → 打开**全屏**验证页过一次人机验证，换 Cookie 后再试一次 HTTP。
    //    验证页只在需要时出现，主页仍然没有任何 WebView。
    if (body == null && mounted) {
      final verifyProxy = candidates.isEmpty ? null : candidates.first;
      final port = await _startProxy(state, verifyProxy, hasLine);
      final verified = await Navigator.of(context).push<CensysVerifyResult>(
        MaterialPageRoute(
          builder: (_) => CensysVerifyPage(apiUrl: _apiUrl),
        ),
      );
      await _clearProxy();

      if (verified == null) {
        lastError ??= '已取消人机验证';
        state.pushLog('用户取消了人机验证');
      } else {
        if (verified.cookie.isNotEmpty) {
          state.settings.censysCookie = verified.cookie;
          usedCookie = true;
          await state.saveSettings();
          state.pushLog('已保存 Censys Cookie（${verified.cookie.length} 字节）');
        }
        body = verified.json;
        viaVerify = body != null;
        if (body == null && verified.cookie.isNotEmpty) {
          // 验证页通常只拿到 Cookie（页面本身是搜索页/挑战页），用它再试一次纯 HTTP
          final retry = await fetchCensysJson(
            query: query,
            cookie: verified.cookie,
            proxyPort: port,
          );
          body = retry.json;
          viaVerify = body != null;
          lastError = retry.error ?? lastError;
          if (body == null) {
            state.pushLog('用验证后的 Cookie 重试仍失败：${retry.error}');
          }
        }
        if (body != null && verifyProxy != null) {
          _usedProxy = verifyProxy.key;
          await state.recordProxyResult(verifyProxy, true);
        }
      }
    }

    if (!mounted) return;
    if (body == null) {
      setState(() {
        _fetching = false;
        _error = lastError ?? '没有拿到数据';
        _diag = '失败';
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
      final via = viaVerify ? '经验证页完成' : '直连 API';
      final cookieNote = usedCookie ? ' · 已复用验证' : '';
      _diag = '$via$cookieNote'
          '${_usedProxy == null ? '' : ' · proxyip $_usedProxy'}';
    });
    _toast('获取成功：$hits 条');
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

  /// 用 [proxy] 起单线路代理并把本机设备代理指向它的端口。
  ///
  /// 返回 null 表示没有可用端口：`hasLine == false`（没配线路，走直连）时这是正常值；
  /// `hasLine == true` 时说明线路没起来，调用方应记一次 proxyip failure 换下一条。
  Future<int?> _startProxy(AppState state, ProxyIp? proxy, bool hasLine) async {
    if (!hasLine) {
      _usedProxyPort = null;
      await _clearProxy();
      return null;
    }
    try {
      await state.startLineWith(proxy);
      final port = state.xray.running ? state.xray.port : null;
      _usedProxyPort = port;
      if (port != null) {
        await _setProxy(port);
      } else {
        await _clearProxy();
      }
      return port;
    } on Object catch (e) {
      state.pushLog('线路启动失败（proxyip=${proxy?.key ?? "原样"}）：$e');
      return null;
    }
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
