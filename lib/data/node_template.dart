import 'dart:convert';

/// 与桌面端 node_template.go / Android NodeTemplate 对齐。
/// 返回 host:port 槽位的 [start, end) 区间。
(int, int)? linkSlot(String link) {
  final scheme = link.indexOf('://');
  if (scheme < 0) return null;
  final head = scheme + 3;

  var hash = link.indexOf('#', head);
  if (hash < 0) hash = link.length;

  var query = link.indexOf('?', head);
  if (query < 0) {
    query = hash;
  } else if (query > hash) {
    query = hash;
  }
  if (query <= head) return null;

  final at = link.lastIndexOf('@', query - 1);
  if (at < head) return null;

  final hostPort = link.substring(at + 1, query);
  final colon = hostPort.lastIndexOf(':');
  if (colon <= 0 || colon == hostPort.length - 1) return null;
  final port = hostPort.substring(colon + 1);
  if (port.length > 5 || int.tryParse(port) == null) return null;
  return (at + 1, query);
}

bool hasSlot(String link) => linkSlot(link) != null;

String bindLink(String link, String target) {
  final slot = linkSlot(link);
  if (slot == null) return link;
  return link.replaceRange(slot.$1, slot.$2, target);
}

/// 模板 × 候选 → 节点列表。
List<String> expandTemplate(String template, List<String> targets) {
  final lines = template
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (lines.isEmpty) return const [];

  final out = <String>[];
  for (final line in lines) {
    if (!hasSlot(line)) {
      out.add(line);
      continue;
    }
    for (final t in targets) {
      out.add(bindLink(line, t));
    }
  }
  return out;
}

/// base64 订阅正文，与 LinkCodec.base64Encode 一致。
String subscription(List<String> links) =>
    base64Encode(utf8.encode(links.join('\n')));
