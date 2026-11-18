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
