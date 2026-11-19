import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/mihomo.dart';
import 'package:cytest/data/vless.dart';

/// 给第三方内核写配置时，**SNI / Host 必须是 ASCII**。
///
/// Go 的 `crypto/tls` 不做 IDNA 转换：把 `е.eu.org`（西里尔 е）原样写进
/// `serverName`，发出去就是非法 SNI，CDN 直接拒绝握手 → 用户看到
/// 「所有节点 TLS 握手失败」。mihomo 的 `servername` / WS `Host` 同理。
///
/// 这组测试钉住「配置里永远不出现非 ASCII 主机名」。
void main() {
  // U+0435（西里尔小写 е），肉眼与拉丁 e 完全一样。
  const cyrillic = '\u0435.eu.org';
  const uuid = 'b831381d-6324-4d53-ad4f-8cda48b30811';

  final link = 'vless://$uuid@$cyrillic:443?encryption=none&security=tls'
      '&sni=$cyrillic&type=ws&host=$cyrillic&path=%2Fws';

  test('Xray 出站：serverName / WS Host / 地址都转成 punycode', () {
    final v = Vless.tryParse(link);
    expect(v, isNotNull, reason: '含 IDN 的 vless 链接应能解析');

    final cfg = buildXrayConfig(v!, 20001);
    final outbound = (cfg['outbounds'] as List).first as Map;
    final stream = outbound['streamSettings'] as Map;

    expect((stream['tlsSettings'] as Map)['serverName'], 'xn--e1a.eu.org',
        reason: 'SNI 必须是 punycode，否则 Go 侧握手必失败');

    final ws = stream['wsSettings'] as Map;
    expect((ws['headers'] as Map)['Host'], 'xn--e1a.eu.org',
        reason: 'HTTP Host 头只允许 ASCII');

    final vnext =
        ((outbound['settings'] as Map)['vnext'] as List).first as Map;
    expect(vnext['address'], 'xn--e1a.eu.org',
        reason: '出站地址里的域名也要归一');
  });

  test('mihomo：servername 与 ws Host 同样是 punycode', () {
    final yaml = buildMihomoConfig([link]).yaml;

    expect(yaml, contains('xn--e1a.eu.org'));
    expect(yaml.contains(cyrillic), isFalse,
        reason: '生成的 YAML 里不允许残留非 ASCII 主机名');
  });

  test('xhttp：settings 里带 path / mode / host（缺 host 会被按 Host 分流的反代拒绝）', () {
    final v = Vless.tryParse(
      'vless://$uuid@101.34.32.230:22304?type=xhttp&security=tls'
      '&sni=$cyrillic&host=$cyrillic&path=%2F&mode=auto',
    )!;
    final cfg = buildXrayConfig(v, 20001);
    final outbound = (cfg['outbounds'] as List).first as Map;
    final stream = outbound['streamSettings'] as Map;
    final xhttp = stream['xhttpSettings'] as Map;

    expect(stream['network'], 'xhttp');
    expect(xhttp['path'], '/');
    expect(xhttp['mode'], 'auto');
    expect(xhttp['host'], 'xn--e1a.eu.org');
  });

  test('纯 ASCII / IP 原样保留，不被改写', () {
    final v = Vless.tryParse(
      'vless://$uuid@104.16.1.1:443?security=tls&sni=example.com&type=ws'
      '&host=example.com&path=%2Fws',
    )!;
    final cfg = buildXrayConfig(v, 20001);
    final outbound = (cfg['outbounds'] as List).first as Map;
    final stream = outbound['streamSettings'] as Map;

    expect((stream['tlsSettings'] as Map)['serverName'], 'example.com');
    expect(((stream['wsSettings'] as Map)['headers'] as Map)['Host'],
        'example.com');
    final vnext =
        ((outbound['settings'] as Map)['vnext'] as List).first as Map;
    expect(vnext['address'], '104.16.1.1');
  });
}
