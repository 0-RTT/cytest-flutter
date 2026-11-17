/// Censys 抓取的纯 HTTP 通道（**不碰 WebView**）。
///
/// 为什么要有它：实测 Censys 对未认证请求返回的是 **HTTP 200 + 3KB 挑战页 HTML**
/// （带 `Content-Security-Policy: default-src 'self'`），不是 403 也不是 JSON。
/// 挑战页的 CSP 会挡掉任何注入的 `fetch`，所以 headless WebView 里那句
/// `fetch('/api/search')` 必然报 `TypeError: Failed to fetch`。
///
/// 结论：**WebView 只用来过一次人机验证换 Cookie**，真正的数据请求走这里的
/// `HttpClient`（带 Cookie + 完整浏览器头），既快又不受 CSP 限制。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' show Cookie;

/// 与验证页/抓取共用的桌面 UA。
const String kCensysUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// Censys 站点与搜索接口。
const String kCensysOrigin = 'https://platform.censys.io';
const String kCensysSearchPath = '/api/search';

/// 一次纯 HTTP 抓取的结果。
class CensysHttpResult {
  const CensysHttpResult({
    this.json,
    this.statusCode,
    this.contentType,
    this.bytes = 0,
    this.error,
    this.head = '',
  });

  /// 成功时的 JSON 原文（已通过 [censysJsonOrNull] 校验）。
  final String? json;

  final int? statusCode;

  /// 响应 `Content-Type` 的 mime 部分，例如 `application/json` / `text/html`。
  final String? contentType;

  /// 响应体字节数（诊断用）。
  final int bytes;

  /// 失败原因（可读中文）。
  final String? error;

  /// 响应体开头 120 字符，失败时用于判断「是不是挑战页」。
  final String head;

  bool get ok => json != null;
}

/// 判定「这段文本是不是 Censys 搜索结果」。
///
/// 直连 `/api/search` 有三种可能：
/// 1. 有 Cookie：JSON 对象，含 `results` 字段 → 返回原文（两侧空白已 trim）；
/// 2. 无 Cookie：**HTTP 200 + HTML 挑战页**（含 `<html`/`<!DOCTYPE` 与 CSP 头）；
/// 3. 其它错误响应：JSON 但不是搜索结果（如 `{"status":"error"}`）。
/// 2、3 一律返回 null，交给调用方走「验证页换 Cookie」。
///
/// 单独抽成顶层函数：这是整个抓取链路的唯一判据，也最容易写错
/// （把 HTML 当数据、或忘了校验 `results`），必须能脱离 WebView 单测。
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

/// 把 Cookie 列表拼成 `Cookie:` 请求头的值：`a=1; b=2`。
///
/// 规则（都与真实抓包一致）：
/// - 空列表 → 空串（**不要**返回 `"; "` 之类，会让服务端认为带了空 cookie）；
/// - 跳过 name 为空的项；value 为 null/空也保留 `name=`（有些服务端要求出现该键）；
/// - 同名只保留最后一个（后写入的覆盖先写入的，与浏览器一致）；
/// - 未知/非法字符不做转义 —— Cookie 值本身就是 header 安全字符，
///   多此一举的转义反而会让服务端不认。
String buildCookieHeader(Iterable<Cookie> cookies) {
  final merged = <String, String>{};
  for (final cookie in cookies) {
    final name = cookie.name.trim();
    if (name.isEmpty) continue;
    final value = cookie.value;
    merged[name] = value == null ? '' : '$value';
  }
  if (merged.isEmpty) return '';
  return merged.entries.map((e) => '${e.key}=${e.value}').join('; ');
}

/// 把 `document.cookie` 的原始串（`a=1; b=2`）规范化；空输入返回空串。
///
/// 作为 [CookieManager.getCookies] 不可用时的兜底（`document.cookie` 读不到
/// HttpOnly，但 Cloudflare 的挑战 cookie 一般不是 HttpOnly）。
String normalizeDocumentCookie(String raw) {
  final parts = raw
      .split(';')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty && e.contains('='))
      .toList(growable: false);
  return parts.join('; ');
}

/// 纯 HTTP 抓取 Censys 搜索接口。
///
/// [cookie] 为空串表示不带 Cookie（第一次抓取就是这种情况，必然拿到挑战页）。
/// [proxyPort] 非空时走本机 Xray 入站口（`PROXY 127.0.0.1:port`）。
Future<CensysHttpResult> fetchCensysJson({
  required String query,
  String cookie = '',
  int? proxyPort,
  String userAgent = kCensysUserAgent,
  Duration connectTimeout = const Duration(seconds: 10),
  Duration readTimeout = const Duration(seconds: 30),
}) async {
  final uri = Uri.parse(
    '$kCensysOrigin$kCensysSearchPath?q=${Uri.encodeQueryComponent(query)}',
  );
  final client = HttpClient()
    ..connectionTimeout = connectTimeout
    ..userAgent = userAgent;
  if (proxyPort != null) {
    client.findProxy = (Uri _) => 'PROXY 127.0.0.1:$proxyPort';
  }

  try {
    final request = await client.getUrl(uri);
    request.followRedirects = true;
    // 完整浏览器头：缺 Referer / Sec-Fetch-* 时，即便带 Cookie 也更容易被判为
    // 脚本请求而重新触发挑战（与真实抓包对比过）。
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/json, text/plain, */*')
      ..set(HttpHeaders.acceptLanguageHeader, 'zh-CN,zh;q=0.9,en;q=0.8')
      ..set(HttpHeaders.refererHeader, '$kCensysOrigin/search')
      ..set('Sec-Fetch-Site', 'same-origin')
      ..set('Sec-Fetch-Mode', 'cors')
      ..set('Sec-Fetch-Dest', 'empty');
    if (cookie.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookie);
    }

    final response = await request.close().timeout(readTimeout);
    final contentType = response.headers.contentType?.mimeType ?? '';
    final body =
        await response.transform(utf8.decoder).join().timeout(readTimeout);

    final parsed = censysJsonOrNull(body);
    // 判定必须同时看 contentType：挑战页是 text/html，但偶发情况下 HTML 也可能
    // 以 JSON 开头（例如被中间层包了一层），只看 body 开头会误判。
    final isJson = contentType.contains('json');
    if (parsed != null && isJson) {
      return CensysHttpResult(
        json: parsed,
        statusCode: response.statusCode,
        contentType: contentType,
        bytes: body.length,
      );
    }
    return CensysHttpResult(
      statusCode: response.statusCode,
      contentType: contentType,
      bytes: body.length,
      head: _head(body, 120),
      error: _describe(response.statusCode, contentType, body.length),
    );
  } on Object catch (e) {
    return CensysHttpResult(error: _humanize(e));
  } finally {
    client.close(force: true);
  }
}

String _describe(int status, String contentType, int bytes) {
  final type = contentType.isEmpty ? '未知类型' : contentType;
  if (contentType.contains('html')) {
    return 'HTTP $status · $type · $bytes 字节 —— 这是人机验证页，需要过一次验证';
  }
  if (status < 200 || status >= 300) {
    return 'HTTP $status · $type · $bytes 字节';
  }
  return 'HTTP $status · $type · $bytes 字节（不是 Censys 搜索结果）';
}

String _humanize(Object error) {
  if (error is SocketException) {
    return '连接失败：${error.message}';
  }
  if (error is TimeoutException) return '请求超时';
  if (error is HandshakeException) return 'TLS 握手失败：${error.message}';
  if (error is HttpException) return 'HTTP 错误：${error.message}';
  return '$error';
}

String _head(String s, int limit) {
  if (s.length <= limit) return s;
  var end = limit;
  final unit = s.codeUnitAt(end - 1);
  if (unit >= 0xD800 && unit <= 0xDBFF && end < s.length) end += 1;
  return '${s.substring(0, end)}…';
}
