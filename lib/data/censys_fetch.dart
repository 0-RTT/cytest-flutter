/// Censys 抓取的**编排层**：决定这次走「纯 HTTP 快路径」还是「原生 WebView」。
///
/// 为什么要有这一层：页面（`fetch_page.dart`）里做这种判定无法单测 —— 它同时要
/// 起 Xray、切换系统代理、拿状态串。把「什么时候试 HTTP、失败算什么性质、
/// Cookie 怎么回写」抽成纯编排后，全部决策都能用假函数钉死。
///
/// 站点行为（依据 `lib/data/censys_http.dart` 与 `censys_native.dart` 的实测注释）：
/// - 干净的出口 IP：直连 `/api/search` 直接给 JSON；
/// - 老 Cookie + 干净出口：**可能**也给 JSON（Fastly 分级放行），这就是快路径的全部价值；
/// - 可疑出口：HTTP 200 + 挑战页 HTML，必须让 WebView 跑一次；
/// - 被 TLS 指纹拦：纯 HTTP 根本连不上（SocketException / 握手失败）。
///
/// 所以三种失败要区别对待，不能一律重试：
/// 1. 拿到 HTML 挑战页 / 401 / 403 → Cookie 过期或无效，**清掉**，下次重新拿；
/// 2. 连不上（没有状态码）→ Cookie 救不了，**本会话内不再试**，省下每次的等待；
/// 3. 其它（如 `{"status":"error"}`）→ 与应用状态无关（可能是 CQL 语法错），
///    保持现状，用户改查询后下次仍值得一试。
library;

import 'censys_http.dart';
import 'censys_native.dart';

/// 这次数据是走哪条路拿到的。
enum CensysPath { http, webview }

/// 纯 HTTP 失败后的处置方式。
enum CensysFallback {
  /// Cookie 无效 → 清空，并继续走 WebView。
  clearCookie,

  /// 连不上（TLS 指纹 / 超时 / 无出口）→ 本会话内禁用快路径。
  disableHttp,
}

/// 一次抓取的状态载体（页面持有一个，跨多次抓取复用）。
///
/// 它同时承担两件事：
/// - **共享事实**：`cookie` 与 `httpDisabled` 决定下一次还试不试 HTTP；
/// - **变更信号**：`cookieDirty` 只在 Cookie 真的变了时为真，页面据此决定要不要落盘。
///   没有它会退化成「每次抓取都写一次 SharedPreferences」。
class CensysFetchPlan {
  CensysFetchPlan({
    this.cookie = '',
    this.httpDisabled = false,
    this.maxHttpFailures = 2,
  });

  /// 当前 `Cookie:` 头值（空串 = 没有）。
  String cookie;

  /// 本会话是否已判定「纯 HTTP 用不上」。
  bool httpDisabled;

  /// 允许连续未命中几次就停手。
  ///
  /// 为什么需要它：WebView 每成功一次都会写回新 Cookie，下一条线路又会带着
  /// 「新 Cookie」去试 HTTP。若该站点的挑战是**按出口 IP**判定的，这条快路径
  /// 会每次抓取都白等 1~2s，且永远不收敛。给个上界后最坏只浪费两次。
  final int maxHttpFailures;

  /// 本会话内纯 HTTP 未命中的次数（含「清 Cookie 后回退」）。
  int httpFailures = 0;

  bool _cookieDirty = false;

  /// Cookie 自上次落盘后是否变过。
  bool get cookieDirty => _cookieDirty;

  /// 写入新 Cookie；值没变就不标脏。
  void setCookie(String value) {
    final next = value.trim();
    if (next == cookie) return;
    cookie = next;
    _cookieDirty = true;
  }

  void clearCookie() => setCookie('');

  void disableHttp() {
    httpDisabled = true;
  }

  /// 记一次未命中；达到 [maxHttpFailures] 就永久停手（本会话）。
  void noteHttpFailure() {
    httpFailures += 1;
    if (httpFailures >= maxHttpFailures) httpDisabled = true;
  }

  /// 落盘成功后调用，避免同一变更被重复写。
  void clearDirty() {
    _cookieDirty = false;
  }
}

/// 一次抓取的结果。
class CensysFetchOutcome {
  const CensysFetchOutcome({
    required this.json,
    required this.path,
    this.httpNote,
  });

  /// 已验证过的 Censys 搜索结果 JSON（`{"results": ...}`）。
  final String json;

  final CensysPath path;

  /// 走 WebView 时，纯 HTTP 为什么没命中（给状态串展示；没有快路径时为 null）。
  final String? httpNote;

  bool get viaHttp => path == CensysPath.http;
}

/// 是否值得先试纯 HTTP。
///
/// 两条都必须满足：有 Cookie（否则必然拿挑战页，白等一次）且本会话没被禁。
bool shouldTryHttp({required String cookie, required bool httpDisabled}) =>
    !httpDisabled && cookie.trim().isNotEmpty;

/// 判定纯 HTTP 失败的**性质**（`null` = 保持现状）。
///
/// 判据全部取自 [CensysHttpResult] 的结构化字段，**不要改成语义匹配 `error` 文案**：
/// 文案是给人看的，改一个字就会让这里静默失效。
CensysFallback? judgeHttpFailure(CensysHttpResult result) {
  if (result.ok) return null;
  // 没有状态码 = 请求根本没走通（解析失败 / 连接重置 / 握手失败 / 超时）。
  // 这类失败与 Cookie 无关，重试只是重复等待。
  if (result.statusCode == null) return CensysFallback.disableHttp;
  final type = result.contentType ?? '';
  if (type.contains('html')) return CensysFallback.clearCookie;
  if (result.statusCode == 401 || result.statusCode == 403) {
    return CensysFallback.clearCookie;
  }
  return null;
}

/// 纯 HTTP 探测的注入点（默认接真实实现）。
typedef CensysHttpProbe = Future<CensysHttpResult> Function(
  String query,
  String cookie,
  int? proxyPort,
);

/// 原生 WebView 抓取的注入点。
typedef CensysWebViewFetch = Future<String> Function(
  String query,
  int? proxyPort,
);

/// 从 WebView 内核读 Cookie 的注入点。
typedef CensysCookieReader = Future<String> Function();

/// 抓一次：有 Cookie 先试纯 HTTP，失败按性质处置后回退原生 WebView。
///
/// 副作用只落在 [plan] 上（Cookie 变更 / 禁用快路径），不碰设置文件 ——
/// 落盘由调用方决定（见 `fetch_page.dart` 的 `cookieDirty` 处理）。
///
/// 抛 [CensysNativeException]：WebView 兜底也失败时原样上抛。
/// **注意**：此时 [plan] 里可能已经有变更（例如刚清掉过期 Cookie），
/// 调用方必须照常落盘。
Future<CensysFetchOutcome> fetchCensysOnce({
  required CensysFetchPlan plan,
  required String query,
  int? proxyPort,
  CensysHttpProbe? httpProbe,
  CensysWebViewFetch? webviewFetch,
  CensysCookieReader? readCookie,
  Duration httpConnectTimeout = const Duration(seconds: 6),
  Duration httpReadTimeout = const Duration(seconds: 12),
}) async {
  final probe = httpProbe ??
      (q, cookie, port) => fetchCensysJson(
            query: q,
            cookie: cookie,
            proxyPort: port,
            connectTimeout: httpConnectTimeout,
            readTimeout: httpReadTimeout,
          );
  final webview = webviewFetch ?? defaultCensysWebViewFetch;
  final reader = readCookie ?? readCensysCookie;

  String? httpNote;
  if (shouldTryHttp(cookie: plan.cookie, httpDisabled: plan.httpDisabled)) {
    final result = await probe(query, plan.cookie, proxyPort);
    final json = result.json;
    if (json != null) {
      return CensysFetchOutcome(json: json, path: CensysPath.http);
    }
    httpNote = result.error ?? '纯 HTTP 未返回 Censys 搜索结果';
    // 先记一次未命中（有上界），再按失败性质做具体处置 —— 两者不互斥：
    // 挑战页除了「清 Cookie」，也该计入「这条快路径大概不划算」。
    plan.noteHttpFailure();
    switch (judgeHttpFailure(result)) {
      case CensysFallback.clearCookie:
        plan.clearCookie();
      case CensysFallback.disableHttp:
        plan.disableHttp();
      case null:
        break;
    }
  }

  // 快路径没命中：WebView 是唯一可靠通道（它能过 Fastly 挑战）。
  final json = await webview(query, proxyPort);
  // 抓成功后立刻把内核 Cookie 收回来：下次才有资格走快路径。
  // 读不到不算失败（部分机型 CookieManager 未就绪），保持原值即可。
  final fresh = await reader();
  if (fresh.trim().isNotEmpty) plan.setCookie(fresh);
  return CensysFetchOutcome(
    json: json,
    path: CensysPath.webview,
    httpNote: httpNote,
  );
}

/// 默认的原生 WebView 抓取（抽成顶层函数，便于在测试里被替换）。
///
/// 为什么要包一层而不能直接传 [fetchCensysSearch]：后者的参数全是具名的，
/// 类型 `Future<String> Function({required String query, ...})` 与
/// [CensysWebViewFetch] 的位置参数类型不兼容，编译期就过不去。
Future<String> defaultCensysWebViewFetch(String query, int? proxyPort) =>
    fetchCensysSearch(query: query, proxyPort: proxyPort);