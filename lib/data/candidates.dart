import 'dart:convert';

/// 从「Censys 存档 JSON」或「历史 result.csv」中提取 `ip:port` 候选。
///
/// 规则（容错优先，**任何情况都不抛异常**）：
/// - 内容 trim 后以 `{` / `[` 开头 → 按 JSON 解析，取
///   `results.hits[].host.ip` + `.port`（找不到时回退到 hit 自身的 `ip` / `port`）；
/// - 否则按 CSV 解析：首行若含 `IP` / `Port` 视为表头跳过，每行取前两列；
/// - 空行、注释行（`#` 开头）、非法端口（非 1..65535）一律跳过；
/// - 结果按出现顺序去重（保序），解析失败返回空列表。
List<String> extractTargets(String content) {
  final text = content.trim();
  if (text.isEmpty) return const [];
  if (text.startsWith('{') || text.startsWith('[')) {
    return _extractFromJson(text);
  }
  return _extractFromCsv(text);
}

/// JSON 分支：拿到 hits 列表后逐条取 host.ip / port。
List<String> _extractFromJson(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return const [];
  } on Object {
    // jsonDecode 只抛 FormatException，这里兜底封闭任何意外实现。
    return const [];
  }

  final hits = _hitsOf(decoded);
  if (hits == null) return const [];

  final seen = <String>{};
  final out = <String>[];
  for (final hit in hits) {
    if (hit is! Map) continue;
    // 规范位置：results.hits[].host.ip / .port；
    // 兼容位置：results.hits[].host.host.ip（pipeline.go 的解析结构）、
    //          hit.ip / hit.port（部分导出把 host 拍平了）。
    Map? host = hit['host'] is Map ? hit['host'] as Map : null;
    if (host != null && host['ip'] == null && host['host'] is Map) {
      host = host['host'] as Map;
    }
    final ipSource = host?['ip'] ?? hit['ip'];
    final portSource = host?['port'] ?? hit['port'];
    final ip = ipSource == null ? '' : '$ipSource'.trim();
    if (!_validIp(ip)) continue;

    final ports = <int>[];
    final single = _parsePort(portSource);
    if (single != null) {
      ports.add(single);
    } else if (host != null && host['services'] is List) {
      // Censys 真实响应把端口放在 services[]，只在 host.port 缺失时回退。
      for (final service in host['services'] as List) {
        if (service is! Map) continue;
        final p = _parsePort(service['port']);
        if (p != null) ports.add(p);
      }
    }
    for (final port in ports) {
      final key = '$ip:$port';
      if (seen.add(key)) out.add(key);
    }
  }
  return out;
}

/// 从顶层响应里找到 hits 列表；结构不符返回 null。
List<dynamic>? _hitsOf(Object? decoded) {
  if (decoded is List) return decoded;
  if (decoded is! Map) return null;
  final results = decoded['results'];
  if (results is Map && results['hits'] is List) {
    return results['hits'] as List;
  }
  if (decoded['hits'] is List) return decoded['hits'] as List;
  return null;
}

/// CSV 分支：表头可选，每行前两列是 IP、Port。
List<String> _extractFromCsv(String text) {
  final lines = text.replaceFirst('\uFEFF', '').split(RegExp(r'\r?\n'));
  final out = <String>[];
  final seen = <String>{};
  var firstLine = true;

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (firstLine) {
      firstLine = false;
      if (_looksLikeHeader(line)) continue;
    }
    if (line.startsWith('#')) continue;

    final cells = line.split(',');
    if (cells.length < 2) continue;

    final ip = _unquote(cells[0]);
    if (!_validIp(ip)) continue;
    final port = _parsePort(_unquote(cells[1]));
    if (port == null) continue;

    final key = '$ip:$port';
    if (seen.add(key)) out.add(key);
  }
  return out;
}

/// 首行是否表头：首列是 `IP` 或第二列是 `Port`（大小写不敏感，允许带引号）。
///
/// 不用「整行 contains」：那样 `proxyip,...` 这种数据行会被误判成表头。
/// 先用 [_unquote] 去掉包裹引号，否则 `"IP","Port"` 这种引号表头只能靠
/// 「Port 不是数字」的通用规则兜底，属于隐式双重依赖。
bool _looksLikeHeader(String line) {
  final cells = line.split(',');
  final first = cells.isEmpty ? '' : _unquote(cells.first).toLowerCase();
  if (first == 'ip') return true;
  if (cells.length > 1 && _unquote(cells[1]).toLowerCase() == 'port') {
    return true;
  }
  return false;
}

String _unquote(String cell) {
  var value = cell.trim();
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    value = value.substring(1, value.length - 1).trim();
  }
  return value;
}

/// IP 是否形态合法：非空且不含空白。
bool _validIp(String ip) => ip.isNotEmpty && !ip.contains(RegExp(r'\s'));

/// 端口解析：接受 int / double / 数字字符串，范围 1..65535，其余返回 null。
int? _parsePort(Object? value) {
  if (value == null) return null;
  final int? port;
  if (value is int) {
    port = value;
  } else if (value is num) {
    port = value.toInt();
  } else {
    port = int.tryParse('$value'.trim());
  }
  if (port == null || port < 1 || port > 65535) return null;
  return port;
}
