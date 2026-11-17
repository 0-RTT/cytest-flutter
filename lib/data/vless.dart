import 'dart:convert';

/// 与 Android VlessParser / 桌面端 parseVless 对齐。
class Vless {
  final String uuid;
  final String host;
  final int port;
  final String network;
  final String security;
  final String sni;
  final String wsHost;
  final String wsPath;
  final String alpn;
  final String fingerprint;
  final String mode;
  final String name;

  const Vless({
    required this.uuid,
    required this.host,
    required this.port,
    required this.network,
    required this.security,
    required this.sni,
    required this.wsHost,
    required this.wsPath,
    required this.alpn,
    required this.fingerprint,
    required this.mode,
    required this.name,
  });

  static Vless? tryParse(String link) {
    final raw = link.trim();
    if (raw.isEmpty || !raw.toLowerCase().startsWith('vless://')) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;

    final uuid = uri.userInfo;
    final host = uri.host;
    final port = uri.hasPort ? uri.port : 0;
    if (uuid.isEmpty || host.isEmpty || port <= 0) return null;

    final q = uri.queryParameters;
    final network = (q['type'] ?? 'tcp').toLowerCase();
    final security = (q['security'] ?? 'none').toLowerCase();

    return Vless(
      uuid: uuid,
      host: host,
      port: port,
      network: network,
      security: security,
      sni: q['sni'] ?? '',
      wsHost: q['host'] ?? '',
      wsPath: (q['path'] ?? '/').isEmpty ? '/' : q['path']!,
      alpn: q['alpn'] ?? '',
      fingerprint: q['fp'] ?? '',
      mode: (q['mode'] ?? '').isEmpty ? 'auto' : q['mode']!,
      name: _decodeFragment(uri.fragment),
    );
  }

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'host': host,
        'port': port,
        'network': network,
        'security': security,
        'sni': sni,
        'wsHost': wsHost,
        'wsPath': wsPath,
        'alpn': alpn,
        'fingerprint': fingerprint,
        'mode': mode,
        'name': name,
      };
}

/// Dart 的 Uri.fragment 不会自动解码，这里显式解码以与 Kotlin 版行为一致。
String _decodeFragment(String raw) {
  if (raw.isEmpty) return '';
  try {
    return Uri.decodeComponent(raw);
  } catch (_) {
    return raw;
  }
}

class ProxyIp {
  final String ip;
  final int port;

  const ProxyIp(this.ip, this.port);

  String get key => '$ip:$port';

  @override
  String toString() => key;
}

/// ws/xhttp 路径里的 ip:port 槽位，与 ProxyIpRepository.PATH_IP_RE 一致。
final _pathIpRe = RegExp(r'^/([0-9A-Za-z.\-]+):(\d+)(\?.*)?$', dotAll: true);

String? pathProxyIp(String path) {
  final m = _pathIpRe.firstMatch(path.trim());
  if (m == null) return null;
  return '${m.group(1)}:${m.group(2)}';
}

String replacePathIp(String path, ProxyIp item) {
  final m = _pathIpRe.firstMatch(path.trim());
  if (m == null) return path;
  final suffix = m.group(3) ?? '';
  return '/${item.ip}:${item.port}$suffix';
}

/// 宽容解析 proxyip 文本（每行 ip:port，允许逗号后缀与 # 注释）。
List<ProxyIp> parseProxyCsv(String text) {
  final seen = <String>{};
  final out = <ProxyIp>[];
  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final first = line.split(RegExp(r'[,\t; ]')).first;
    final idx = first.lastIndexOf(':');
    if (idx <= 0 || idx == first.length - 1) continue;
    final ip = first.substring(0, idx).trim();
    final portStr = first.substring(idx + 1).trim();
    final port = int.tryParse(portStr);
    if (ip.isEmpty || port == null || port <= 0 || port > 65535) continue;
    final key = '$ip:$port';
    if (!seen.add(key)) continue;
    out.add(ProxyIp(ip, port));
  }
  return out;
}

/// 构造 Xray 配置，字段与桌面端 buildXrayConfig 逐项对齐。
Map<String, dynamic> buildXrayConfig(Vless v, int localPort, {ProxyIp? proxy}) {
  var path = v.wsPath;
  if (proxy != null && pathProxyIp(path) != null) {
    path = replacePathIp(path, proxy);
  }

  final stream = <String, dynamic>{
    'network': v.network,
    'security': v.security,
  };

  if (v.security == 'tls') {
    final sni = v.sni.isNotEmpty ? v.sni : v.wsHost;
    final tls = <String, dynamic>{};
    if (sni.isNotEmpty) tls['serverName'] = sni;
    if (v.alpn.isNotEmpty) {
      tls['alpn'] = v.alpn
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    if (v.fingerprint.isNotEmpty) tls['fingerprint'] = v.fingerprint;
    stream['tlsSettings'] = tls;
  }

  switch (v.network) {
    case 'ws':
      final ws = <String, dynamic>{'path': path};
      if (v.wsHost.isNotEmpty) {
        ws['headers'] = {'Host': v.wsHost};
      }
      stream['wsSettings'] = ws;
      break;
    case 'xhttp':
      stream['xhttpSettings'] = {
        'path': path,
        'mode': v.mode.isEmpty ? 'auto' : v.mode,
      };
      break;
  }

  return {
    'log': {'loglevel': 'warning'},
    'inbounds': [
      {
        'tag': 'mixed',
        'listen': '127.0.0.1',
        'port': localPort,
        'protocol': 'mixed',
        'settings': {'auth': 'noauth', 'udp': true},
        'sniffing': {
          'enabled': true,
          'destOverride': ['http', 'tls'],
        },
      }
    ],
    'outbounds': [
      {
        'tag': 'proxy',
        'protocol': 'vless',
        'settings': {
          'vnext': [
            {
              'address': v.host,
              'port': v.port,
              'users': [
                {'id': v.uuid, 'encryption': 'none'}
              ],
            }
          ],
        },
        'streamSettings': stream,
        'mux': {'enabled': false, 'concurrency': -1},
      },
      {'tag': 'direct', 'protocol': 'freedom'},
      {'tag': 'block', 'protocol': 'blackhole'},
    ],
    'routing': {'domainStrategy': 'AsIs', 'rules': <dynamic>[]},
  };
}

String xrayConfigJson(Vless v, int localPort, {ProxyIp? proxy}) =>
    const JsonEncoder.withIndent('  ')
        .convert(buildXrayConfig(v, localPort, proxy: proxy));
