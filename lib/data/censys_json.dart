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

int? _asnOf(Map hit) {
  final direct = _asInt(hit['asn']);
  if (direct != null) return direct;

  final as = hit['autonomous_system'];
  if (as is Map) {
    final fromAs = _asInt(as['asn']);
    if (fromAs != null) return fromAs;
  }
  final host = hit['host'];
  if (host is Map) {
    final hostAs = host['autonomous_system'];
    if (hostAs is Map) {
      final nested = _asInt(hostAs['asn']);
      if (nested != null) return nested;
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
