import 'dart:convert';

import 'vless.dart';

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

/// mihomo 配置，字段与桌面端 mihomo.go 对齐。
String buildMihomoYaml(Vless v, List<String> targets) {
  const groupMain = '🚀 节点选择';
  const groupAuto = '⚡ 自动选择';
  const healthUrl = 'http://www.gstatic.com/generate_204';

  String yamlScalar(String s) {
    if (s.isEmpty) return '""';
    final safe = RegExp(r'^[\w\-./:@ \u4e00-\u9fff]+$').hasMatch(s) &&
        !s.startsWith('-');
    if (safe) return s;
    return '"${s.replaceAll('"', r'\"')}"';
  }

  final b = StringBuffer()
    ..writeln('mixed-port: 7890')
    ..writeln('allow-lan: false')
    ..writeln('mode: rule')
    ..writeln('log-level: info')
    ..writeln()
    ..writeln('proxies:');

  final names = <String>[];
  var index = 0;
  for (final target in targets) {
    final parts = target.split(':');
    if (parts.length < 2) continue;
    final host = parts.sublist(0, parts.length - 1).join(':');
    final port = int.tryParse(parts.last);
    if (port == null) continue;

    index++;
    final name = '${index.toString().padLeft(2, '0')} · $host';
    names.add(name);

    b
      ..writeln('  - name: ${yamlScalar(name)}')
      ..writeln('    type: vless')
      ..writeln('    server: ${yamlScalar(host)}')
      ..writeln('    port: $port')
      ..writeln('    uuid: ${yamlScalar(v.uuid)}');

    if (v.network.isNotEmpty && v.network != 'tcp') {
      b.writeln('    network: ${v.network}');
    }
    if (v.security == 'tls') {
      b.writeln('    tls: true');
      final sni = v.sni.isNotEmpty ? v.sni : v.wsHost;
      if (sni.isNotEmpty) b.writeln('    servername: ${yamlScalar(sni)}');
    }
    if (v.alpn.isNotEmpty) {
      b.writeln('    alpn:');
      for (final a in v.alpn.split(',').map((e) => e.trim())) {
        if (a.isNotEmpty) b.writeln('      - ${yamlScalar(a)}');
      }
    }
    if (v.fingerprint.isNotEmpty) {
      b.writeln('    client-fingerprint: ${v.fingerprint}');
    }
    switch (v.network) {
      case 'ws':
        b
          ..writeln('    ws-opts:')
          ..writeln('      path: ${yamlScalar(v.wsPath)}');
        if (v.wsHost.isNotEmpty) {
          b
            ..writeln('      headers:')
            ..writeln('        Host: ${yamlScalar(v.wsHost)}');
        }
        break;
      case 'xhttp':
        b
          ..writeln('    xhttp-opts:')
          ..writeln('      path: ${yamlScalar(v.wsPath)}');
        if (v.mode.isNotEmpty) {
          b.writeln('      mode: ${v.mode}');
        }
        break;
    }
  }

  if (names.isEmpty) return '';

  b
    ..writeln()
    ..writeln('proxy-groups:')
    ..writeln('  - name: ${yamlScalar(groupMain)}')
    ..writeln('    type: select')
    ..writeln('    proxies:')
    ..writeln('      - ${yamlScalar(groupAuto)}');
  for (final n in names) {
    b.writeln('      - ${yamlScalar(n)}');
  }
  b
    ..writeln('      - DIRECT')
    ..writeln('  - name: ${yamlScalar(groupAuto)}')
    ..writeln('    type: url-test')
    ..writeln('    url: $healthUrl')
    ..writeln('    interval: 300')
    ..writeln('    tolerance: 50')
    ..writeln('    proxies:');
  for (final n in names) {
    b.writeln('      - ${yamlScalar(n)}');
  }

  b
    ..writeln()
    ..writeln('rules:')
    ..writeln('  - DOMAIN-SUFFIX,local,DIRECT')
    ..writeln('  - IP-CIDR,127.0.0.0/8,DIRECT')
    ..writeln('  - IP-CIDR,192.168.0.0/16,DIRECT')
    ..writeln('  - IP-CIDR,10.0.0.0/8,DIRECT')
    ..writeln('  - GEOIP,CN,DIRECT')
    ..writeln('  - MATCH,$groupMain');

  return b.toString();
}
