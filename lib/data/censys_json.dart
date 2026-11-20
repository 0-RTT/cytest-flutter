import 'dart:convert';

/// 判定「这段文本是不是 Censys 搜索结果」——整个抓取链路的唯一判据。
///
/// WebView 原生侧已经做过一轮判断，Dart 侧再校验一次是因为 channel 可能
/// 回传异常内容（空串 / 挑战页 / 错误 JSON）。判据必须只看结构化内容，
/// 不要改成语义匹配 `error` 文案。
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

/// 从 Censys 搜索结果里取「出现最多的 ASN」，返回 `AS13335` 形式；取不到返回 null。
///
/// 为什么取众数而不是第一条：一次搜索常常跨多个 AS，但绝大多数命中落在同一个
/// 骨干/云厂商（例如 Cloudflare 的 13335）。用众数当文件名，才能一眼看出
/// 「这份数据是哪个网段的」；而第一条命中完全取决于排序，不稳定。
///
/// 只读结构化字段（`autonomous_system.asn`，兼容 `host.autonomous_system.asn`
/// 与纯 `asn`），不解析任何文案。任何异常都返回 null —— 命名失败不该让抓取失败。
String? dominantAsn(String json) {
  Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on Object {
    return null;
  }
  final results = decoded is Map ? decoded['results'] : null;
  final hits = results is Map ? results['hits'] : null;
  if (hits is! List) return null;

  final counter = <int, int>{};
  for (final hit in hits) {
    if (hit is! Map) continue;
    final asn = _asnOf(hit);
    if (asn == null || asn <= 0) continue;
    counter[asn] = (counter[asn] ?? 0) + 1;
  }
  if (counter.isEmpty) return null;

  // 次数相同则取 ASN 小的，保证同样的数据永远得到同样的名字（可复现）。
  final entries = counter.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  return 'AS${entries.first.key}';
}

/// 在一个 hit 里找 ASN。
///
/// 为什么用**递归兜底**而不是只查固定路径：Censys 的响应结构随接口版本变过好几次
/// （`asn` 直接在 hit 上 / `autonomous_system.asn` / `host.autonomous_system.asn`，
/// 还有 `host.services` 里带 `matched_services` 的版本）。写死路径一旦对不上，
/// 命名就静默退回 `unknown`，表现成「ASN 没生效」——这种失败很难在真机上报出来。
/// 递归找名字是 `asn` / `as_number` 的键，深度限 6，代价可以忽略。
int? _asnOf(Object? node, [int depth = 0]) {
  if (node == null || depth > 6) return null;
  if (node is Map) {
    for (final key in const ['asn', 'as_number', 'asn_number']) {
      final v = _asInt(node[key]);
      if (v != null && v > 0) return v;
    }
    final as = node['autonomous_system'];
    if (as is Map) {
      for (final key in const ['asn', 'number', 'as_number']) {
        final v = _asInt(as[key]);
        if (v != null && v > 0) return v;
      }
    }
    for (final v in node.values) {
      final found = _asnOf(v, depth + 1);
      if (found != null) return found;
    }
    return null;
  }
  if (node is List) {
    for (final v in node) {
      final found = _asnOf(v, depth + 1);
      if (found != null) return found;
    }
  }
  return null;
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim().replaceAll('AS', '').replaceAll('as', ''));
  return null;
}

/// 归一化用户输入的 CQL。
///
/// 用户经常直接从浏览器地址栏复制整条 URL，或者复制已经编码过的查询串：
/// - 整条 URL：`https://platform.censys.io/api/search?q=host.x:JP+and+...`
/// - 地址栏编码：空格变成 `+`、引号变成 `%22`、花括号变成 `%7B`…
///
/// 这两种形式如果原样发给服务端，`+` 会被当成字面加号、`%22` 会被二次编码成
/// `%2522`，Censys 直接返回 CQL 语法错误 —— 表现就是「明明浏览器有数据，
/// 应用里却提示不是搜索结果」。所以必须先还原成真正的查询语句。
String normalizeCql(String raw) {
  var q = raw.trim();
  if (q.isEmpty) return q;

  // 1) 整条 URL：取 q= 参数（Uri 会自动把 %xx 和 + 还原）。
  if (q.startsWith('http://') || q.startsWith('https://')) {
    final uri = Uri.tryParse(q);
    final fromQuery = uri?.queryParameters['q'];
    if (fromQuery != null && fromQuery.trim().isNotEmpty) return fromQuery.trim();
    return q;
  }

  // 2) 已编码的查询串。
  if (q.contains('%')) {
    try {
      final decoded = Uri.decodeQueryComponent(q).trim();
      if (decoded.isNotEmpty) return decoded;
    } on ArgumentError {
      // 不是合法编码（例如正则里本来就有 %）：原样使用。
    }
  } else if (q.contains('+')) {
    // 没有 % 但出现 +：这是地址栏把空格编码成 + 的形式。
    q = q.replaceAll('+', ' ').trim();
  }
  return q;
}
