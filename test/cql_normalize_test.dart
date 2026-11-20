import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/censys_json.dart';

void main() {
  const cql = 'host.location.country_code:JP and '
      'host.services.endpoints.http.body_hash_sha1="108b6115dc6ebfde76aef4336126f605252d957f" and '
      'host.autonomous_system.asn:{4713,7679,9365}';

  group('normalizeCql · 用户粘贴形式归一化', () {
    test('整条 URL：取 q= 参数并还原 %xx / +', () {
      final url = 'https://platform.censys.io/api/search?q='
          '${Uri.encodeQueryComponent(cql)}';
      expect(normalizeCql(url), cql);
    });

    test('地址栏形式（+ 当空格、引号花括号已编码）', () {
      final encoded = cql
          .replaceAll(' ', '+')
          .replaceAll('"', '%22')
          .replaceAll('{', '%7B')
          .replaceAll('}', '%7D');
      expect(normalizeCql(encoded), cql);
    });

    test('只有 + 没有 % 时按空格处理', () {
      expect(normalizeCql('a:JP+and+b:US'), 'a:JP and b:US');
    });

    test('本来就是正常 CQL：原样返回（含冒号、引号、花括号、逗号）', () {
      expect(normalizeCql('  $cql  '), cql);
    });

    test('非法编码不抛异常，原样返回', () {
      expect(normalizeCql('host.x:100%'), 'host.x:100%');
    });
  });
}
