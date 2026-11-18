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

/// mihomo 配置，与 Kotlin `MihomoYaml.build(links, options)` 的核心段对齐。
///
/// 关键差异（相对旧实现）：接收**已展开的链接列表**而不是模板 + 裸地址，
/// 每条链接独立解析；节点名取 `#备注`（解码后），空则 `节点-N`，与 Kotlin
/// 的 `proxy["name"] = url.remark.ifEmpty { "节点-$index" }` 一致。
/// 重名按 Kotlin `dedupe` 追加 ` (2)`、` (3)`。
String buildMihomoYaml(List<String> links) {
  const groupMain = '🚀 节点选择';
  const groupAuto = '⚡ 自动选择';
  const healthUrl = 'http://www.gstatic.com/generate_204';

  // Kotlin SAFE_PLAIN = ^[A-Za-z0-9_][A-Za-z0-9_./-]*$，中文名必须加引号。
  final safePlain = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_./-]*$');
  final reserved = RegExp(r'^(true|false|yes|no|on|off|null|~)$',
      caseSensitive: false);
  final numeric = RegExp(r'^-?\d+(\.\d+)?$');

  String quote(String s) =>
      '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  String scalar(String s) {
    if (s.isEmpty) return '""';
    if (reserved.hasMatch(s) || numeric.hasMatch(s)) return quote(s);
    if (safePlain.hasMatch(s)) return s;
    return quote(s);
  }

  final proxies = <Map<String, String>>[];
  final errors = <String>[];
  for (var i = 0; i < links.length; i++) {
    final v = Vless.tryParse(links[i]);
    if (v == null) {
      errors.add('第 ${i + 1} 条解析失败');
      continue;
    }
    final name = v.name.isNotEmpty ? v.name : '节点-${i + 1}';
    final p = <String, String>{
      'name': name,
      'server': v.host,
      'port': '${v.port}',
      'uuid': v.uuid,
    };
    final sni = v.sni.isNotEmpty ? v.sni : v.wsHost;
    final tls = v.security == 'tls' || v.security == 'reality';
    if (tls) {
      if (sni.isNotEmpty) p['servername'] = sni;
      if (v.fingerprint.isNotEmpty) {
        p['client-fingerprint'] = v.fingerprint;
      }
      // Kotlin: alpn 为空且 network=ws 时补 http/1.1
      final alpn = v.alpn.isEmpty
          ? (v.network == 'ws' ? 'http/1.1' : '')
          : v.alpn;
      if (alpn.isNotEmpty) p['alpn'] = alpn;
    }

    // Kotlin applyTransport：只保留 ws / xhttp 两种（原版核心段）
    final transport = StringBuffer();
    switch (v.network) {
      case 'ws':
        transport
          ..writeln('    network: ws')
          ..writeln('    ws-opts:')
          ..writeln('      path: ${scalar(v.wsPath)}');
        if (v.wsHost.isNotEmpty) {
          transport
            ..writeln('      headers:')
            ..writeln('        Host: ${scalar(v.wsHost)}');
        }
        break;
      case 'xhttp':
        transport
          ..writeln('    network: xhttp')
          ..writeln('    xhttp-opts:')
          ..writeln('      path: ${scalar(v.wsPath)}');
        if (v.mode.isNotEmpty) {
          transport.writeln('      mode: ${scalar(v.mode)}');
        }
        break;
    }
    p['_transport'] = transport.toString();
    proxies.add(p);
  }
  if (proxies.isEmpty) {
    // 不静默降级：全部解析失败时把原因带进异常，由页面显示给用户。
    throw ArgumentError(errors.isEmpty ? '没有可解析的节点' : errors.join('；'));
  }

  // Kotlin dedupe：同名追加 " (2)"、" (3)"
  final seen = <String, int>{};
  final names = <String>[];
  for (final p in proxies) {
    final base = p['name']!;
    final n = (seen[base] ?? 0) + 1;
    seen[base] = n;
    final finalName = n == 1 ? base : '$base ($n)';
    p['name'] = finalName;
    names.add(finalName);
  }

  final b = StringBuffer()
    ..writeln('mixed-port: 7890')
    ..writeln('allow-lan: false')
    ..writeln('mode: rule')
    ..writeln('log-level: info')
    ..writeln()
    ..writeln('proxies:');

  for (final p in proxies) {
    // 顺序与 Kotlin linkedMapOf 一致：name/type/server/port/uuid/...
    b
      ..writeln('  - name: ${scalar(p['name']!)}')
      ..writeln('    type: vless')
      ..writeln('    server: ${scalar(p['server']!)}')
      ..writeln('    port: ${p['port']}')
      ..writeln('    uuid: ${scalar(p['uuid']!)}');
    if (p.containsKey('servername')) {
      b.writeln('    servername: ${scalar(p['servername']!)}');
    }
    if (p.containsKey('client-fingerprint')) {
      b.writeln('    client-fingerprint: ${scalar(p['client-fingerprint']!)}');
    }
    if (p.containsKey('alpn')) {
      b.writeln('    alpn: [${p['alpn']!.split(',').map((e) => scalar(e.trim())).join(', ')}]');
    }
    b.write(p['_transport']);
  }

  b
    ..writeln()
    ..writeln('proxy-groups:')
    ..writeln('  - name: ${scalar(groupMain)}')
    ..writeln('    type: select')
    ..writeln('    proxies:')
    ..writeln('      - ${scalar(groupAuto)}');
  for (final n in names) {
    b.writeln('      - ${scalar(n)}');
  }
  b
    ..writeln('      - DIRECT')
    ..writeln('  - name: ${scalar(groupAuto)}')
    ..writeln('    type: url-test')
    ..writeln('    url: $healthUrl')
    ..writeln('    interval: 300')
    ..writeln('    tolerance: 50')
    ..writeln('    lazy: true')
    ..writeln('    proxies:');
  for (final n in names) {
    b.writeln('      - ${scalar(n)}');
  }

  b
    ..writeln()
    ..writeln('rules:')
    ..writeln('  - DOMAIN-SUFFIX,local,DIRECT')
    ..writeln('  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve')
    ..writeln('  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve')
    ..writeln('  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve')
    ..writeln('  - GEOIP,CN,DIRECT')
    ..writeln('  - MATCH,$groupMain');

  return b.toString();
}
