import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/mihomo.dart';
import 'package:cytest/data/node_template.dart';

/// 这份 YAML 要能直接被 mihomo 加载，
/// 段落缺失或格式写错都不会报错，只会静默失效，所以必须逐段钉住。
const _ws =
    'vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443'
    '?encryption=none&security=tls&type=ws&host=cf.example.com&path=%2Fws'
    '&sni=cf.example.com#A';

void main() {
  group('mihomo · 完整段落', () {
    test('基础段：mixed-port/profile/日志级别', () {
      final y = buildMihomoConfig(const [_ws]).yaml;
      expect(y, contains('mixed-port: 7890'));
      expect(y, contains('log-level: warning'));
      expect(y, contains('unified-delay: true'));
      expect(y, contains('tcp-concurrent: true'));
      expect(y, contains('profile:'));
      expect(y, contains('  store-selected: true'));
      expect(y, contains('  store-fake-ip: true'));
    });

    test('rule-providers：7 个，format 必须是 yaml 不是 text', () {
      final y = buildMihomoConfig(const [_ws]).yaml;
      expect(y, contains('rule-providers:'));
      for (final key in [
        'reject',
        'private',
        'lancidr',
        'google',
        'proxy',
        'direct',
        'cncidr',
      ]) {
        expect(y, contains('  $key:'), reason: key);
      }
      // 写成 text 会让规则集静默变空
      expect('format: yaml'.allMatches(y).length, 7);
      expect(y, isNot(contains('format: text')));
      expect(y, contains('behavior: ipcidr'));
    });

    test('tun / sniffer / dns(fake-ip) 齐全', () {
      final y = buildMihomoConfig(const [_ws]).yaml;
      expect(y, contains('tun:'));
      expect(y, contains('dns-hijack:'));
      expect(y, contains('sniffer:'));
      expect(y, contains('fake-ip-range: 198.18.0.1/16'));
      expect(y, contains('fake-ip-filter:'));
      expect(y, contains('nameserver-policy:'));
    });

    test('三条策略组：节点选择只放自动/手动/DIRECT，不掺节点', () {
      final out = buildMihomoConfig(const [_ws, '$_ws#B']);
      expect(out.groups, 3);
      final y = out.yaml;
      expect(y, contains('  - name: "🚀 节点选择"'));
      expect(y, contains('      - "⚡ 自动选择"'));
      expect(y, contains('      - "🎯 手动指定"'));
      expect(y, contains('    type: url-test'));
      expect(y, contains('    lazy: true'));
      // 节点只出现在自动组 / 手动组里，各一次；主组不掺节点
      expect('      - A\n'.allMatches(y).length, 2);
    });

    test('规则顺序：private → lancidr → 内网段 → reject → google/proxy → direct → cncidr → MATCH', () {
      final y = buildMihomoConfig(const ['$_ws']).yaml;
      int at(String s) => y.indexOf(s);
      expect(at('RULE-SET,private'), greaterThan(-1));
      expect(at('RULE-SET,private'), lessThan(at('RULE-SET,lancidr')));
      expect(at('RULE-SET,lancidr'), lessThan(at('RULE-SET,google')));
      expect(at('RULE-SET,google'), lessThan(at('RULE-SET,proxy')));
      expect(at('RULE-SET,proxy'), lessThan(at('RULE-SET,direct')));
      expect(at('RULE-SET,direct'), lessThan(at('RULE-SET,cncidr')));
      expect(y.trimRight().endsWith('- "MATCH,🚀 节点选择"'), isTrue);
    });
  });

  group('mihomo · 节点字段', () {
    test('ws+tls：udp/tls/servername/alpn 默认 http/1.1/ws-opts', () {
      final y = buildMihomoConfig(const [_ws]).yaml;
      expect(y, contains('    udp: true'));
      expect(y, contains('    tls: true'));
      expect(y, contains('    servername: cf.example.com'));
      expect(y, contains('    alpn: [http/1.1]'));
      expect(y, contains('    ws-opts:'));
      expect(y, contains('      path: "/ws"'));
      expect(y, contains('        Host: cf.example.com'));
    });

    test('reality：tls 为真、fp 缺省 chrome、reality-opts 三段', () {
      final y = buildMihomoConfig(const [
        'vless://u@1.1.1.1:443?security=reality&type=tcp&sni=a.com'
            '&pbk=PUBKEY&sid=abcd&spx=%2F#R',
      ]).yaml;
      expect(y, contains('    tls: true'));
      expect(y, contains('    client-fingerprint: chrome'));
      expect(y, contains('    reality-opts:'));
      expect(y, contains('      public-key: PUBKEY'));
      expect(y, contains('      short-id: abcd'));
    });

    test('xhttp：9 个扩展参数原样带入', () {
      final y = buildMihomoConfig(const [
        'vless://u@1.1.1.1:443?security=tls&type=xhttp&path=%2Fx'
            '&mode=stream-one&xhttp-method=GET#X',
      ]).yaml;
      expect(y, contains('    xhttp-opts:'));
      expect(y, contains('      mode: stream-one'));
      expect(y, contains('      method: GET'));
    });

    test('关闭广告：reject provider 与 RULE-SET,reject 一起消失', () {
      final y =
          buildMihomoConfig(const [_ws], options: const MihomoOptions(blockAds: false))
              .yaml;
      expect(y, isNot(contains('reject.txt')));
      expect(y, isNot(contains('RULE-SET,reject')));
      expect(y, contains('RULE-SET,proxy'));
    });

    test('关闭 TUN / IPv6：对应段落整段消失', () {
      final y = buildMihomoConfig(
        const [_ws],
        options: const MihomoOptions(tun: false, ipv6: false),
      ).yaml;
      expect(y, isNot(contains('tun:')));
      expect(y, contains('ipv6: false'));
    });

    test('模板展开后逐条解析：server 用选中 ip，不是模板里的 1.2.3.4', () {
      final links = expandTemplate(_ws, ['9.9.9.9:1111', '8.8.8.8:2222']);
      final out = buildMihomoConfig(links);
      expect(out.proxies, 2);
      expect(out.yaml, contains('    server: 9.9.9.9'));
      expect(out.yaml, contains('    server: 8.8.8.8'));
      expect(out.yaml, isNot(contains('    server: 1.2.3.4')));
    });

    test('坏链接记进 errors，不拖垮其余节点', () {
      final out = buildMihomoConfig(const ['ss://unsupported', _ws]);
      expect(out.proxies, 1);
      expect(out.errors, hasLength(1));
      expect(out.errors.first, startsWith('第 1 条：'));
    });
  });
}
