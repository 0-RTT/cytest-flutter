/// proxyip 列表的 CSV 读写。
///
/// **格式与原版 Kotlin `ProxyIpRepository.toCsv` 逐字对齐**：
/// ```
/// IP,Port,Latency (ms),Speed (MiB/s)
/// 104.16.0.1,443,0,0.00
/// ```
/// 这样用户在两端之间来回导同一份文件不会变形（原版 `parseCsv` 依赖
/// `SpeedResultCsv.parse`，要求每行 ≥4 列并识别 `IP`/`Port` 表头）。
///
/// 同时**宽容接受**用户自己维护的简写（原版不认，这里认，属于只增不减的兼容）：
/// - 一行一个 `ip:port`；
/// - 一行 `ip,port`（两列）；
/// - `#` 开头的注释行；
/// - UTF-8 BOM、CRLF / CR 换行、字段两侧空白、双引号包裹。
///
/// 任何解析不出的行**直接跳过**（不抛异常）：用户从别处粘来的列表常常混着
/// 表头、空行和坏行，为一行坏数据整体失败是最差的体验。
library;

import 'vless.dart';

/// 解析 proxyip CSV/文本，返回去重后的列表（保持出现顺序）。
///
/// 去重键是 `ip:port`，与 `ProxyIp.key` 一致，避免同一地址测两遍。
List<ProxyIp> parseProxyIpCsv(String text) {
  final normalized = text
      .replaceFirst('\uFEFF', '') // UTF-8 BOM（Excel 导出常见）
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');

  final out = <ProxyIp>[];
  final seen = <String>{};

  for (final rawLine in normalized.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;

    final cells = _splitCsvLine(line);
    if (cells.isEmpty) continue;
    if (_isHeader(cells)) continue;

    final ip = cells[0].trim();
    var port = cells.length >= 2 ? int.tryParse(cells[1].trim()) : null;

    // 单字段简写 `ip:port`
    if (port == null && cells.length == 1) {
      final idx = ip.lastIndexOf(':');
      if (idx > 0 && idx < ip.length - 1) {
        port = int.tryParse(ip.substring(idx + 1).trim());
        final onlyIp = ip.substring(0, idx).trim();
        if (_validIp(onlyIp) && _validPort(port)) {
          if (seen.add('$onlyIp:$port')) out.add(ProxyIp(onlyIp, port!));
        }
        continue;
      }
    }

    if (!_validIp(ip) || !_validPort(port)) continue;
    if (seen.add('$ip:$port')) out.add(ProxyIp(ip, port!));
  }
  return out;
}

/// 序列化成与原版一致的 4 列 CSV（Latency/Speed 只在原版测速时有值，这里写 0）。
String toProxyIpCsv(List<ProxyIp> list) {
  final buffer = StringBuffer('IP,Port,Latency (ms),Speed (MiB/s)\n');
  for (final item in list) {
    buffer
      ..write(item.ip)
      ..write(',')
      ..write(item.port)
      ..write(',0,0.00\n');
  }
  return buffer.toString();
}

bool _isHeader(List<String> cells) {
  if (cells.isEmpty) return false;
  final first = cells[0].trim().toLowerCase();
  if (first != 'ip') return false;
  // 只认「IP」开头且第二列是 port 类表头，避免把真的有一个叫 ip 的字段当表头
  return cells.length == 1 || cells[1].trim().toLowerCase().startsWith('port');
}

/// IP/主机名的基本合法性：非空、无空白、不含逗号/引号。
///
/// 不强制 IPv4 点分四段：原版允许 proxyip 里写域名（`PATH_IP_RE` 就带 `A-Za-z`）。
bool _validIp(String ip) {
  if (ip.isEmpty || ip.length > 255) return false;
  if (ip.contains(RegExp(r'[\s,"]'))) return false;
  return true;
}

bool _validPort(int? port) => port != null && port >= 1 && port <= 65535;

/// 单行 CSV 拆分，支持双引号包裹与 `""` 转义。
List<String> _splitCsvLine(String line) {
  final cells = <String>[];
  final field = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(ch);
      }
      continue;
    }
    if (ch == '"') {
      inQuotes = true;
    } else if (ch == ',' || ch == '\t' || ch == ';') {
      cells.add(field.toString());
      field.clear();
    } else {
      field.write(ch);
    }
  }
  cells.add(field.toString());
  return cells;
}
