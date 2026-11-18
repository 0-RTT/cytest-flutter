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

  /// 原始 query 参数（键小写，值已解码）。
  ///
  /// mihomo 配置需要 alpn/flow/pbk/sid/spx/servicename/maxearlydata/xhttp-* 等
  /// 二十来个参数，逐个建字段太散，保留整张表更贴合 Kotlin `LinkCodec.query`。
  final Map<String, String> query;

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
    this.query = const {},
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

    // 不用 `uri.queryParameters`：它按 form-urlencoded 语义把 `+` 解成空格，
    // 而 vless 链接的 `+` 是字面量（Kotlin 的 LinkCodec.decode 也特意避开这点）。
    final q = _parseQuery(uri.query);
    final network = (q['type'] ?? q['network'] ?? 'tcp').toLowerCase();
    final security = (q['security'] ?? 'none').toLowerCase();
    final rawPath = q['path'] ?? '';
    final rawMode = q['mode'] ?? '';

    return Vless(
      uuid: _decodeComponent(uuid),
      host: host,
      port: port,
      network: network,
      security: security,
      sni: q['sni'] ?? q['peer'] ?? q['servername'] ?? '',
      wsHost: q['host'] ?? '',
      wsPath: rawPath.isEmpty ? '/' : rawPath,
      alpn: q['alpn'] ?? '',
      fingerprint: q['fp'] ?? q['client-fingerprint'] ?? '',
      mode: rawMode.isEmpty ? 'auto' : rawMode,
      name: _decodeFragment(uri.fragment),
      query: q,
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

/// 解析 query：`a=1&b=2`，键小写，值做百分号解码（**不把 `+` 当空格**）。
Map<String, String> _parseQuery(String raw) {
  if (raw.isEmpty) return const {};
  final out = <String, String>{};
  for (final pair in raw.split('&')) {
    if (pair.isEmpty) continue;
    final cut = pair.indexOf('=');
    final rawKey = cut < 0 ? pair : pair.substring(0, cut);
    final rawValue = cut < 0 ? '' : pair.substring(cut + 1);
    final key = _decodeComponent(rawKey).trim().toLowerCase();
    if (key.isEmpty) continue;
    out[key] = _decodeComponent(rawValue);
  }
  return out;
}

String _decodeComponent(String raw) {
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
