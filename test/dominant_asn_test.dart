import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/censys_json.dart';

/// 存档名里的 ASN 取「命中里的众数」，取不到就 null（调用方回落 unknown）。
void main() {
  String hitsBody(List<int?> asns) => jsonEncode({
        'status': 'ok',
        'results': {
          'total_hits': asns.length,
          'hits': [
            for (final a in asns)
              {
                'host': {'ip': '1.2.3.4', 'port': 443},
                'autonomous_system': {'asn': a, 'name': 'X'},
              },
          ],
        },
      });

  group('dominantAsn · 存档命名用', () {
    test('取出现最多的 ASN，而不是第一条', () {
      // 第一条是 15169，但 13335 出现 3 次 —— 名字必须跟多数派走。
      expect(dominantAsn(hitsBody([15169, 13335, 13335, 13335])), 'AS13335');
    });

    test('次数相同取 ASN 小的，保证同样数据永远同名', () {
      // 4134 < 13335，所以平票时取 4134；两种顺序结果必须一致。
      expect(dominantAsn(hitsBody([4134, 13335])), 'AS4134');
      expect(dominantAsn(hitsBody([13335, 4134])), 'AS4134');
    });

    test('兼容 host.autonomous_system.asn 与纯 asn 字段', () {
      final body = jsonEncode({
        'results': {
          'hits': [
            {'asn': 64500},
            {
              'host': {
                'autonomous_system': {'asn': 64500},
              },
            },
          ],
        },
      });
      expect(dominantAsn(body), 'AS64500');
    });

    test('ASN 是字符串也能解析（"AS13335" / "13335"）', () {
      final body = jsonEncode({
        'results': {
          'hits': [
            {'asn': 'AS13335'},
            {'asn': '13335'},
          ],
        },
      });
      expect(dominantAsn(body), 'AS13335');
    });

    test('取不到 ASN / 非法 JSON / 空 hits 都返回 null（不让命名拖垮抓取）', () {
      expect(dominantAsn(jsonEncode({'results': {'hits': []}})), isNull);
      expect(dominantAsn(jsonEncode({'results': {'hits': [{'host': {}}]}})), isNull);
      expect(dominantAsn('not json'), isNull);
      expect(dominantAsn('{"results":null}'), isNull);
      expect(dominantAsn(''), isNull);
    });
  });

  group('dominantAsn · 结构变体（真机返回过的形状）', () {
    test('Censys Platform：host.autonomous_system + matched_services 并存', () {
      final body = jsonEncode({
        'status': 'success',
        'results': {
          'total_hits': 2,
          'hits': [
            {
              'host': {
                'ip': '104.16.0.1',
                'port': 443,
                'autonomous_system': {'asn': 13335, 'name': 'CLOUDFLARENET'},
                'services': [
                  {'port': 443, 'service_name': 'HTTP'},
                ],
              },
              'matched_services': [
                {'port': 443},
              ],
            },
            {
              'host': {
                'ip': '104.16.0.2',
                'autonomous_system': {'asn': 13335},
              },
            },
          ],
        },
      });
      expect(dominantAsn(body), 'AS13335');
    });

    test('ASN 藏在更深层（services 里的 autonomous_system）也能找到', () {
      final body = jsonEncode({
        'results': {
          'hits': [
            {
              'host': {
                'services': [
                  {
                    'autonomous_system': {'asn': 4713},
                  },
                ],
              },
            },
          ],
        },
      });
      expect(dominantAsn(body), 'AS4713');
    });

    test('as_number 这种别名也认', () {
      final body = jsonEncode({
        'results': {
          'hits': [
            {'as_number': 7679},
          ],
        },
      });
      expect(dominantAsn(body), 'AS7679');
    });
  });
}
