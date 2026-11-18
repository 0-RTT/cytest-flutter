import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/censys_diag.dart';
import 'package:cytest/data/vless.dart';

void main() {
  group('censysRouteDiagnosis · 失败时说清用的是哪条出口', () {
    final v = Vless.tryParse(
      'vless://uuid@line.example.com:443?type=ws&security=tls'
      '&host=cdn.example.com&path=/1.2.3.4:443&alpn=h2,http/1.1#tag',
    )!;

    test('有 proxyip 时打印回源 path 替换前后，以及 Host/SNI/alpn', () {
      final diag = censysRouteDiagnosis(v, const ProxyIp('9.9.9.9', 8443));

      expect(diag, contains('回源 /1.2.3.4:443 → /9.9.9.9:8443'));
      expect(diag, contains('线路 line.example.com:443'));
      expect(diag, contains('Host cdn.example.com'));
      expect(diag, contains('SNI cdn.example.com'));
      expect(diag, contains('alpn h2,http/1.1'));
    });

    test('无 proxyip（链接原样）时 path 不变，SNI 为空要说明用 Host 兜底', () {
      final noSni = Vless.tryParse(
        'vless://uuid@line.example.com:443?type=tcp&path=/1.2.3.4:443',
      )!;
      final diag = censysRouteDiagnosis(noSni, null);

      expect(diag, contains('回源 /1.2.3.4:443 → /1.2.3.4:443'));
      expect(diag, contains('SNI （空，用 Host 兜底）'));
      expect(diag, isNot(contains('alpn')));
    });

    test('没配 vless 时明确写直连，不编造线路信息', () {
      expect(censysRouteDiagnosis(null, null), contains('未配置 vless（直连）'));
    });
  });
}
