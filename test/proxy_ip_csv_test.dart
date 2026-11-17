import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/proxy_ip_csv.dart';
import 'package:cytest/data/vless.dart';

/// 与 Flutter 侧导入/落盘共用的 CSV 规则。
///
/// 关键约束：**必须能读原版 Kotlin 导出的文件**（4 列 + `IP,Port,...` 表头），
/// 同时宽容接受用户手写的 `ip:port` 列表 —— 后者原版不认，这里认，属只增不减。
void main() {
  group('parseProxyIpCsv · 原版 4 列格式', () {
    test('带表头的 4 列 CSV：解析出 ip/port，忽略 Latency/Speed 列', () {
      const csv = 'IP,Port,Latency (ms),Speed (MiB/s)\n'
          '104.16.0.1,443,120,8.50\n'
          '104.17.0.2,8443,0,0.00\n';

      final list = parseProxyIpCsv(csv);

      expect(list.length, 2);
      expect(list[0].ip, '104.16.0.1');
      expect(list[0].port, 443);
      expect(list[1].key, '104.17.0.2:8443');
    });

    test('没有表头也能解析（只按列位置取前两列）', () {
      final list = parseProxyIpCsv('1.1.1.1,443,99,1.23\n');

      expect(list.single.key, '1.1.1.1:443');
    });

    test('UTF-8 BOM + CRLF（Excel 导出最常见的组合）', () {
      final csv =
          '\uFEFFIP,Port,Latency (ms),Speed (MiB/s)\r\n1.1.1.1,443,0,0.00\r\n';

      final list = parseProxyIpCsv(csv);

      expect(list.single.ip, '1.1.1.1');
      expect(list.single.port, 443);
    });
  });

  group('parseProxyIpCsv · 宽容输入', () {
    test('每行一个 ip:port（用户手写列表）', () {
      final list = parseProxyIpCsv('1.1.1.1:443\n2.2.2.2:8443\n');

      expect(list.map((e) => e.key).toList(),
          <String>['1.1.1.1:443', '2.2.2.2:8443']);
    });

    test('每行 ip,port（两列，无表头）', () {
      final list = parseProxyIpCsv('1.1.1.1,443\n2.2.2.2,80\n');

      expect(list.length, 2);
      expect(list[1].port, 80);
    });

    test('# 注释行、空行、行内多余空白都被忽略', () {
      const text = '# 这是我的 proxyip 列表\n'
          '\n'
          '  1.1.1.1:443  \n'
          '\t\n'
          '# 下一段\n'
          '2.2.2.2,8080\n';

      final list = parseProxyIpCsv(text);

      expect(list.map((e) => e.key).toList(),
          <String>['1.1.1.1:443', '2.2.2.2:8080']);
    });

    test('重复项按 ip:port 去重，保留首次出现顺序', () {
      final list = parseProxyIpCsv(
        '1.1.1.1:443\n1.1.1.1,443\n2.2.2.2:443\n1.1.1.1:443\n',
      );

      expect(list.map((e) => e.key).toList(),
          <String>['1.1.1.1:443', '2.2.2.2:443']);
    });

    test('域名形式的 proxyip 也接受（原版正则允许字母）', () {
      final list = parseProxyIpCsv('proxy.example.com:443\n');

      expect(list.single.ip, 'proxy.example.com');
      expect(list.single.port, 443);
    });

    test('双引号包裹的字段能正确取出', () {
      final list = parseProxyIpCsv('"1.1.1.1","443"\n');

      expect(list.single.key, '1.1.1.1:443');
    });
  });

  group('parseProxyIpCsv · 非法行全部跳过（不抛异常、不污染列表）', () {
    test('端口越界 / 非数字 / 缺端口 / 空 ip 都跳过', () {
      const text = '1.1.1.1:0\n' // 端口 0
          '1.1.1.1:70000\n' // 超过 65535
          '1.1.1.1:abc\n' // 端口非数字
          ':443\n' // 缺 ip
          '1.1.1.1\n' // 缺端口
          '1.1.1.1 with space:443\n' // ip 含空白
          '2.2.2.2:8080\n'; // 唯一合法行

      final list = parseProxyIpCsv(text);

      expect(list.length, 1);
      expect(list.single.key, '2.2.2.2:8080');
    });

    test('空文本 / 只有表头 → 空列表（调用方据此提示「没解析出内容」）', () {
      expect(parseProxyIpCsv(''), isEmpty);
      expect(parseProxyIpCsv('   \n\n'), isEmpty);
      expect(parseProxyIpCsv('IP,Port,Latency (ms),Speed (MiB/s)\n'), isEmpty);
    });
  });

  group('toProxyIpCsv · 与原版 toCsv 逐字对齐', () {
    test('表头与列顺序完全一致（原版 parseCsv 依赖它）', () {
      final csv = toProxyIpCsv(const <ProxyIp>[
        ProxyIp('1.1.1.1', 443),
        ProxyIp('2.2.2.2', 8443),
      ]);

      expect(
          csv,
          'IP,Port,Latency (ms),Speed (MiB/s)\n1.1.1.1,443,0,0.00\n'
          '2.2.2.2,8443,0,0.00\n');
    });

    test('写出去再读回来内容不变（往返一致）', () {
      const original = <ProxyIp>[
        ProxyIp('1.1.1.1', 443),
        ProxyIp('9.9.9.9', 80)
      ];

      final restored = parseProxyIpCsv(toProxyIpCsv(original));

      expect(restored.map((e) => e.key).toList(),
          original.map((e) => e.key).toList());
    });
  });
}
