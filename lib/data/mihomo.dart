/// mihomo（Clash Meta）配置生成，与 Kotlin `MihomoYaml` / `mihomo配置生成器-v7`
/// 逐段对齐：base → rule-providers → tun → sniffer → dns → proxies →
/// proxy-groups → rules。
///
/// 为什么不用 yaml 库序列化：原版（Kotlin / 生成器 HTML）是手写 emitter，
/// 缩进、引号、空块省略都有既定规则，用通用库输出会与预期文本不同
/// （例如中文名必须加引号、空 Map 必须整段省略）。这里照搬同一套规则。
library;

import 'vless.dart';

/// 生成选项，默认值与生成器 HTML 的勾选状态一致（全部开启）。
class MihomoOptions {
  const MihomoOptions({
    this.tun = true,
    this.autoGroup = true,
    this.udp = true,
    this.ipv6 = true,
    this.blockAds = true,
    this.lanDns = '',
  });

  /// TUN 模式（接管全部流量）。
  final bool tun;

  /// 两个以上节点时生成「自动选择 / 手动指定」两层组。
  final bool autoGroup;

  /// 节点是否启用 UDP。
  final bool udp;

  final bool ipv6;

  /// 引入 reject 规则集拦截广告。
  final bool blockAds;

  /// 内网 DNS（写入 nameserver-policy 的局域网后缀下）。
  final String lanDns;

  MihomoOptions copyWith({
    bool? tun,
    bool? autoGroup,
    bool? udp,
    bool? ipv6,
    bool? blockAds,
    String? lanDns,
  }) =>
      MihomoOptions(
        tun: tun ?? this.tun,
        autoGroup: autoGroup ?? this.autoGroup,
        udp: udp ?? this.udp,
        ipv6: ipv6 ?? this.ipv6,
        blockAds: blockAds ?? this.blockAds,
        lanDns: lanDns ?? this.lanDns,
      );
}

class MihomoOutput {
  const MihomoOutput({
    required this.yaml,
    required this.proxies,
    required this.groups,
    required this.errors,
  });

  final String yaml;
  final int proxies;
  final int groups;

  /// 解析失败的链接（`第 N 条：原因`），供页面提示；不影响其余节点。
  final List<String> errors;
}

const _groupMain = '🚀 节点选择';
const _groupAuto = '⚡ 自动选择';
const _groupManual = '🎯 手动指定';
const _healthUrl = 'http://www.gstatic.com/generate_204';
const _rulesBase =
    'https://testingcf.jsdelivr.net/gh/Loyalsoldier/clash-rules@release';

/// Loyalsoldier/clash-rules 的产物：文件名是 .txt，内容其实是 payload YAML，
/// 所以 `format` 必须写 yaml（写 text 会静默解析成空规则集）。
const _providers = <(String key, String behavior, String file, bool needAds)>[
  ('reject', 'domain', 'reject.txt', true),
  ('private', 'domain', 'private.txt', false),
  ('lancidr', 'ipcidr', 'lancidr.txt', false),
  ('google', 'domain', 'google.txt', false),
  ('proxy', 'domain', 'proxy.txt', false),
  ('direct', 'domain', 'direct.txt', false),
  ('cncidr', 'ipcidr', 'cncidr.txt', false),
];

const _xhttpKeys = <String>[
  'mode',
  'session-table',
  'session-length',
  'session-placement',
  'x-padding-method',
  'x-padding-placement',
  'x-padding-key',
  'x-padding-header',
  'sc-stream-up-server-secs',
];

const _fakeIpFilter = <String>[
  '*.lan',
  '*.local',
  '+.local',
  'localhost.ptlogin2.qq.com',
  '+.msftconnecttest.com',
  '+.msftncsi.com',
  'time.*.com',
  'ntp.*.com',
  '+.pool.ntp.org',
  'stun.*.*',
  '*.n.n.srv.nintendo.net',
  '+.stun.playstation.net',
  'xbox.*.microsoft.com',
  '+.xboxlive.com',
  '*.battlenet.com.cn',
  '*.blzstatic.cn',
  '*.apple.com',
];

final _safePlain = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_./-]*$');
final _reserved =
    RegExp(r'^(true|false|yes|no|on|off|null|~)$', caseSensitive: false);
final _numeric = RegExp(r'^-?\d+(\.\d+)?$');
final _earlyData = RegExp(r'[?&]ed=(\d+)');
final _hasLetter = RegExp('[a-zA-Z]');

/// YAML 标量：布尔/数字直出；保留字与纯数字加引号；中文/空格也加引号。
String _scalar(Object? value) {
  if (value == null) return '""';
  if (value is bool) return value ? 'true' : 'false';
  if (value is int || value is double) return '$value';
  final s = '$value';
  if (s.isEmpty) return '""';
  if (_reserved.hasMatch(s) || _numeric.hasMatch(s)) return _quote(s);
  if (_safePlain.hasMatch(s)) return s;
  return _quote(s);
}

String _quote(String s) =>
    '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

bool _truthy(String? raw) {
  if (raw == null) return false;
  final text = raw.toLowerCase();
  return text.isEmpty || text == '1' || text == 'true' || text == 'yes' ||
      text == 'on';
}

int _toPort(String? raw, int fallback) {
  final port = int.tryParse((raw ?? '').trim());
  if (port == null || port < 1 || port > 65535) return fallback;
  return port;
}

List<String> _splitCsv(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  return raw
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
}

/// 生成完整配置。解析失败的链接记进 `errors`，其余照常输出。
MihomoOutput buildMihomoConfig(
  List<String> links, {
  MihomoOptions options = const MihomoOptions(),
}) {
  final parsed = <Map<String, Object>>[];
  final errors = <String>[];
  for (var i = 0; i < links.length; i++) {
    try {
      parsed.add(_parseLink(links[i], i + 1, options));
    } on Object catch (e) {
      errors.add('第 ${i + 1} 条：${e is FormatException ? e.message : e}');
    }
  }
  if (parsed.isEmpty) {
    return MihomoOutput(yaml: '', proxies: 0, groups: 0, errors: errors);
  }

  final proxies = _dedupe(parsed);
  final names = proxies.map((p) => p['name']! as String).toList();
  final groups = options.autoGroup && names.length >= 2 ? 3 : 1;

  final out = <String>[
    ..._base(options),
    ..._ruleProviders(options),
    ..._tun(options),
    ..._sniffer(),
    ..._dns(options),
    '',
  ];
  _emitProxies(proxies, out);
  out.addAll(_groups(names, options));
  out.addAll(_rules(options));
  out.add('');

  return MihomoOutput(
    yaml: out.join('\n'),
    proxies: proxies.length,
    groups: groups,
    errors: errors,
  );
}

Map<String, Object> _parseLink(String line, int index, MihomoOptions options) {
  final text = line.trim();
  if (!text.toLowerCase().startsWith('vless://')) {
    throw const FormatException('当前只支持 vless 链接');
  }
  final v = Vless.tryParse(text);
  if (v == null) throw const FormatException('链接格式不完整');

  final q = v.query;
  final network = (q['type'] ?? q['network'] ?? 'tcp').toLowerCase();
  final security = (q['security'] ?? '').toLowerCase();
  final tls = security == 'tls' || security == 'reality' || _truthy(q['tls']);

  final hostParam = q['host'] ?? '';
  final sniQ = q['sni'] ?? q['peer'] ?? q['servername'] ?? '';
  // SNI 回落：sni 参数 → host 参数（仅当是域名）→ 服务器地址
  final sni = sniQ.isNotEmpty
      ? sniQ
      : (_hasLetter.hasMatch(hostParam) ? hostParam : v.host);
  final fingerprint = (q['fp'] ?? q['client-fingerprint'] ?? '').isNotEmpty
      ? (q['fp'] ?? q['client-fingerprint'])!
      : (security == 'reality' ? 'chrome' : '');
  final hostHeader = hostParam.isNotEmpty ? hostParam : sni;
  final insecure = _truthy(q['allowinsecure']) ||
      _truthy(q['insecure']) ||
      _truthy(q['skip-cert-verify']);

  final p = <String, Object>{
    'name': v.name.isNotEmpty ? v.name : '节点-$index',
    'type': 'vless',
    'server': v.host,
    'port': _toPort('${v.port}', 443),
    'uuid': v.uuid,
  };
  final flow = q['flow'];
  if (flow != null && flow.isNotEmpty) p['flow'] = flow;
  p['udp'] = options.udp;
  p['tls'] = tls;

  if (tls) {
    if (sni.isNotEmpty) p['servername'] = sni;
    if (fingerprint.isNotEmpty) p['client-fingerprint'] = fingerprint;
    // WS over TLS 未指定 alpn 时默认 http/1.1：h2 会阻断 WS 的 Upgrade
    final alpn = _splitCsv(q['alpn']);
    final effective =
        alpn.isNotEmpty ? alpn : (network == 'ws' ? const ['http/1.1'] : const []);
    if (effective.isNotEmpty) p['alpn'] = effective;
    if (insecure) p['skip-cert-verify'] = true;
  }

  if (security == 'reality') {
    final reality = <String, Object>{};
    final pbk = q['pbk'] ?? q['public-key'] ?? '';
    final sid = q['sid'] ?? q['short-id'] ?? '';
    final spx = q['spx'] ?? q['spiderx'] ?? '';
    if (pbk.isNotEmpty) reality['public-key'] = pbk;
    if (sid.isNotEmpty) reality['short-id'] = sid;
    if (spx.isNotEmpty) reality['spider-x'] = spx;
    if (reality.isNotEmpty) p['reality-opts'] = reality;
  }

  p['network'] = network;
  _applyTransport(p, network, q['path'] ?? '', hostHeader, q);
  return p;
}

void _applyTransport(
  Map<String, Object> p,
  String network,
  String rawPath,
  String hostHeader,
  Map<String, String> q,
) {
  switch (network) {
    case 'ws':
      var path = rawPath.isEmpty ? '/' : rawPath;
      var maxEd = q['maxearlydata'] ?? q['ed'] ?? '';
      final m = _earlyData.firstMatch(path);
      if (m != null) {
        if (maxEd.isEmpty) maxEd = m.group(1)!;
        path = path.replaceRange(m.start, m.end, '');
      }
      if (path.isEmpty) path = '/';
      final ws = <String, Object>{'path': path};
      if (hostHeader.isNotEmpty) {
        ws['headers'] = <String, Object>{'Host': hostHeader};
      }
      final ed = int.tryParse(maxEd);
      if (ed != null && ed > 0) ws['max-early-data'] = ed;
      final eh = q['eh'] ?? q['earlydataheadername'] ?? '';
      if (eh.isNotEmpty) ws['early-data-header-name'] = eh;
      p['ws-opts'] = ws;

    case 'grpc':
      final service = (q['servicename'] ?? q['service-name'] ?? '')
          .isNotEmpty
          ? (q['servicename'] ?? q['service-name'])!
          : rawPath.replaceFirst(RegExp(r'^/'), '');
      if (service.isNotEmpty) {
        p['grpc-opts'] = <String, Object>{'grpc-service-name': service};
      }

    case 'h2' || 'http':
      final h2 = <String, Object>{
        'path': rawPath.isEmpty ? const ['/'] : _splitCsv(rawPath),
      };
      if (hostHeader.isNotEmpty) h2['host'] = _splitCsv(hostHeader);
      p['h2-opts'] = h2;

    case 'xhttp':
      final xo = <String, Object>{
        'path': (q['xhttp-path']?.isNotEmpty ?? false)
            ? q['xhttp-path']!
            : (rawPath.isEmpty ? '/' : rawPath),
      };
      if (hostHeader.isNotEmpty) xo['host'] = hostHeader;
      for (final key in _xhttpKeys) {
        final value = q[key];
        if (value != null && value.isNotEmpty) xo[key] = value;
      }
      final method = q['xhttp-method'];
      if (method != null && method.isNotEmpty) xo['method'] = method;
      p['xhttp-opts'] = xo;
  }
}

List<Map<String, Object>> _dedupe(List<Map<String, Object>> proxies) {
  final seen = <String, int>{};
  return proxies.map((p) {
    final base = p['name']! as String;
    final n = (seen[base] ?? 0) + 1;
    seen[base] = n;
    if (n == 1) return p;
    return <String, Object>{...p, 'name': '$base ($n)'};
  }).toList();
}

List<String> _base(MihomoOptions o) => [
      'mixed-port: 7890',
      'allow-lan: false',
      'mode: rule',
      'log-level: warning',
      'ipv6: ${o.ipv6}',
      'unified-delay: true',
      'tcp-concurrent: true',
      'find-process-mode: off',
      '',
      'profile:',
      '  store-selected: true',
      '  store-fake-ip: true',
    ];

List<String> _ruleProviders(MihomoOptions o) {
  final out = <String>['', 'rule-providers:'];
  var first = true;
  for (final p in _providers) {
    if (p.$4 && !o.blockAds) continue;
    if (!first) out.add('');
    first = false;
    out
      ..add('  ${p.$1}:')
      ..add('    type: http')
      ..add('    behavior: ${p.$2}')
      ..add('    format: yaml')
      ..add('    url: "$_rulesBase/${p.$3}"')
      ..add('    path: ./ruleset/${p.$1}.yaml')
      ..add('    interval: 86400');
  }
  return out;
}

List<String> _tun(MihomoOptions o) {
  if (!o.tun) return const [];
  return const [
    '',
    'tun:',
    '  enable: true',
    '  stack: mixed',
    '  auto-route: true',
    '  strict-route: true',
    '  auto-detect-interface: true',
    '  dns-hijack:',
    '    - any:53',
    '    - tcp://any:53',
  ];
}

List<String> _sniffer() => const [
      '',
      'sniffer:',
      '  enable: true',
      '  force-dns-mapping: true',
      '  parse-pure-ip: true',
      '  override-destination: false',
      '  sniff:',
      '    HTTP:',
      '      ports: [80, 8080-8880]',
      '    TLS:',
      '      ports: [443, 8443]',
      '    QUIC:',
      '      ports: [443, 8443]',
      '  skip-domain:',
      '    - "Mijia Cloud"',
      '    - "+.push.apple.com"',
    ];

List<String> _dns(MihomoOptions o) {
  final out = <String>[
    '',
    'dns:',
    '  enable: true',
    '  ipv6: ${o.ipv6}',
    '  listen: 0.0.0.0:1053',
    '  prefer-h3: false',
    '  cache-algorithm: arc',
    '  use-hosts: true',
    '  use-system-hosts: true',
    '  respect-rules: true',
    '  enhanced-mode: fake-ip',
    '  fake-ip-range: 198.18.0.1/16',
    '  fake-ip-filter-mode: blacklist',
    '  fake-ip-filter:',
    for (final f in _fakeIpFilter) '    - "${f.replaceAll('"', r'\"')}"',
    '  default-nameserver:',
    '    - 223.5.5.5',
    '    - 119.29.29.29',
    '  nameserver:',
    '    - https://cloudflare-dns.com/dns-query',
    '    - https://dns.google/dns-query',
    '  proxy-server-nameserver:',
    '    - https://dns.alidns.com/dns-query',
    '    - https://doh.pub/dns-query',
    '  direct-nameserver:',
    '    - https://dns.alidns.com/dns-query',
    '    - https://doh.pub/dns-query',
    '  nameserver-policy:',
  ];
  for (final domain in const ['"+.lan"', '"+.local"', '"+.home.arpa"']) {
    out.add('    $domain:');
    if (o.lanDns.isNotEmpty) out.add('      - ${_scalar(o.lanDns)}');
    out.add('      - system');
  }
  return out;
}

List<String> _groups(List<String> names, MihomoOptions o) {
  final useAuto = o.autoGroup && names.length >= 2;
  final out = <String>['', 'proxy-groups:'];

  out
    ..add('  - name: ${_scalar(_groupMain)}')
    ..add('    type: select')
    ..add('    proxies:');
  if (useAuto) {
    out
      ..add('      - ${_scalar(_groupAuto)}')
      ..add('      - ${_scalar(_groupManual)}');
  } else {
    // 单节点时没有「自动/手动」之分，直接列节点
    for (final n in names) {
      out.add('      - ${_scalar(n)}');
    }
  }
  out.add('      - DIRECT');

  if (useAuto) {
    out
      ..add('')
      ..add('  - name: ${_scalar(_groupAuto)}')
      ..add('    type: url-test')
      ..add('    url: ${_scalar(_healthUrl)}')
      ..add('    interval: 300')
      ..add('    tolerance: 50')
      ..add('    lazy: true')
      ..add('    proxies:');
    for (final n in names) {
      out.add('      - ${_scalar(n)}');
    }

    out
      ..add('')
      ..add('  - name: ${_scalar(_groupManual)}')
      ..add('    type: select')
      ..add('    proxies:');
    for (final n in names) {
      out.add('      - ${_scalar(n)}');
    }
  }
  return out;
}

List<String> _rules(MihomoOptions o) {
  final out = <String>[
    '',
    'rules:',
    '  - "RULE-SET,private,DIRECT"',
    '  - "RULE-SET,lancidr,DIRECT"',
    '  - "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve"',
    '  - "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve"',
    '  - "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve"',
    '  - "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"',
    '  - "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve"',
    '  - "IP-CIDR6,fc00::/7,DIRECT,no-resolve"',
    '  - "IP-CIDR6,fe80::/10,DIRECT,no-resolve"',
  ];
  if (o.blockAds) out.add('  - "RULE-SET,reject,REJECT"');
  out
    ..add('  - "RULE-SET,google,$_groupMain"')
    ..add('  - "RULE-SET,proxy,$_groupMain"')
    ..add('  - "RULE-SET,direct,DIRECT"')
    ..add('  - "RULE-SET,cncidr,DIRECT"')
    ..add('  - "MATCH,$_groupMain"');
  return out;
}

void _emitProxies(List<Map<String, Object>> proxies, List<String> out) {
  out.add('proxies:');
  for (final p in proxies) {
    var first = true;
    for (final entry in p.entries) {
      final pad = first ? '  - ' : '    ';
      if (_emitEntry(pad, entry.key, entry.value, out)) first = false;
    }
  }
}

bool _emitEntry(String pad, String key, Object value, List<String> out) {
  if (value is List) {
    if (value.isEmpty) return false;
    out.add('$pad$key: [${value.map(_scalar).join(', ')}]');
  } else if (value is Map) {
    if (value.isEmpty) return false;
    out.add('$pad$key:');
    _emitMap(value, 3, out);
  } else {
    out.add('$pad$key: ${_scalar(value)}');
  }
  return true;
}

void _emitMap(Map<Object?, Object?> map, int level, List<String> out) {
  final pad = '  ' * level;
  for (final entry in map.entries) {
    final key = '${entry.key}';
    final value = entry.value;
    if (value is List) {
      if (value.isNotEmpty) {
        out.add('$pad$key: [${value.map(_scalar).join(', ')}]');
      }
    } else if (value is Map) {
      if (value.isNotEmpty) {
        out.add('$pad$key:');
        _emitMap(value, level + 1, out);
      }
    } else {
      out.add('$pad$key: ${_scalar(value)}');
    }
  }
}
