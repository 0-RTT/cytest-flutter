import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/proxy_ip_csv.dart';
import 'package:cytest/data/vless.dart';

/// proxyip 文件的真实格式 = **测速结果 CSV**（原版 `ProxyIpRepository.parseCsv`
/// 直接委托 `SpeedResultCsv.parse`），外加「哪条先用」的排序与状态持久化。
void main() {
  group('parseProxyIpCsv · 真实测速 CSV 格式', () {
    test('表头 + 注释行 + 非法行 + 两处重复 → 条数/去重/跳过都对', () {
      const csv = 'IP,Port,Latency (ms),Speed (MiB/s),Reason\n'
          '# 这是上周跑出来的结果\n'
          '104.16.0.1,443,120,8.50,\n'
          '104.17.0.2,8443,90,12.10,\n'
          '1.1.1.1,0,0,0.00,\n' // 端口 0 → 跳过
          '2.2.2.2,70000,0,0.00,\n' // 端口越界 → 跳过
          '3.3.3.3,abc,0,0.00,\n' // 端口非数字 → 跳过
          '104.16.0.1,443,999,1.00,\n' // 与第 1 行重复 → 去重
          '\n';

      final list = parseProxyIpCsv(csv);

      expect(
        list.map((e) => e.key).toList(),
        <String>['104.16.0.1:443', '104.17.0.2:8443'],
      );
    });

    test('没有表头也能解析（首行不是 IP 就当数据）', () {
      final list = parseProxyIpCsv('1.1.1.1,443,10,1.00\n2.2.2.2,80,20,2.00\n');

      expect(list.length, 2);
      expect(list[1].key, '2.2.2.2:80');
    });

    test('UTF-8 BOM + CRLF（Excel/Windows 导出）', () {
      final csv =
          '\uFEFFIP,Port,Latency (ms),Speed (MiB/s)\r\n1.1.1.1,443,0,0.00\r\n';

      final list = parseProxyIpCsv(csv);

      expect(list.single.key, '1.1.1.1:443');
    });

    test('只有两列（IP,Port）也接受：proxyip 不需要测速字段', () {
      final list = parseProxyIpCsv('IP,Port\n1.1.1.1,443\n2.2.2.2,8443\n');

      expect(list.map((e) => e.key).toList(),
          <String>['1.1.1.1:443', '2.2.2.2:8443']);
    });

    test('单字段 ip:port 不接受（与原版一致：≥2 列才算有效行）', () {
      expect(parseProxyIpCsv('1.1.1.1:443\n'), isEmpty);
    });

    test('空文本 / 只有表头 → 空列表（调用方据此提示「没解析出内容」）', () {
      expect(parseProxyIpCsv(''), isEmpty);
      expect(parseProxyIpCsv('   \n\n'), isEmpty);
      expect(parseProxyIpCsv('IP,Port,Latency (ms),Speed (MiB/s)\n'), isEmpty);
    });
  });

  group('toProxyIpCsv · 与原版 toCsv 逐字对齐', () {
    test('表头与列顺序一致，Latency/Speed 写 0/0.00', () {
      final csv = toProxyIpCsv(const <ProxyIp>[
        ProxyIp('1.1.1.1', 443),
        ProxyIp('2.2.2.2', 8443),
      ]);

      expect(
        csv,
        'IP,Port,Latency (ms),Speed (MiB/s)\n'
        '1.1.1.1,443,0,0.00\n'
        '2.2.2.2,8443,0,0.00\n',
      );
    });

    test('写出再读回内容不变（往返一致，用户可在两端来回导）', () {
      const original = <ProxyIp>[
        ProxyIp('1.1.1.1', 443),
        ProxyIp('9.9.9.9', 80)
      ];

      final restored = parseProxyIpCsv(toProxyIpCsv(original));

      expect(restored.map((e) => e.key).toList(),
          original.map((e) => e.key).toList());
    });
  });

  group('orderProxyIps · 哪条先用（失败少 → 最近成功 → workingKey 优先）', () {
    const a = ProxyIp('1.1.1.1', 443);
    const b = ProxyIp('2.2.2.2', 443);
    const c = ProxyIp('3.3.3.3', 443);

    test('失败次数少的排前面（哪怕它很久没成功过）', () {
      final state = ProxyIpState(stats: <String, ProxyIpStat>{
        a.key: const ProxyIpStat(fail: 2, lastOkAt: 9000),
        b.key: const ProxyIpStat(fail: 0, lastOkAt: 1000),
      });

      final ordered = orderProxyIps(<ProxyIp>[a, b], state);

      expect(ordered.first.key, b.key, reason: 'b 失败 0 次，必须先试');
    });

    test('同失败次数时，最近成功的排前面', () {
      final state = ProxyIpState(stats: <String, ProxyIpStat>{
        a.key: const ProxyIpStat(fail: 0, lastOkAt: 1000),
        b.key: const ProxyIpStat(fail: 0, lastOkAt: 9000),
      });

      final ordered = orderProxyIps(<ProxyIp>[a, b], state);

      expect(ordered.map((e) => e.key).toList(), <String>[b.key, a.key]);
    });

    test('workingKey（上次成功）在零失败时被前移', () {
      final state = ProxyIpState(
        stats: <String, ProxyIpStat>{
          a.key: const ProxyIpStat(lastOkAt: 1000),
          c.key: const ProxyIpStat(lastOkAt: 9000),
        },
        workingKey: a.key,
      );

      final ordered = orderProxyIps(<ProxyIp>[c, a, b], state);

      expect(ordered.first.key, a.key, reason: '上次能用的先试');
    });

    test('recordFailure 之后该条不再前移（fail 升高自然排后）', () {
      var state = const ProxyIpState().recordSuccess(a.key, nowMs: 1000);
      expect(orderProxyIps(<ProxyIp>[b, a], state).first.key, a.key);

      state = state.recordFailure(a.key, nowMs: 2000);
      final ordered = orderProxyIps(<ProxyIp>[a, b], state);

      expect(ordered.first.key, isNot(a.key), reason: '刚失败还排第一就是每次先撞墙');
      expect(state.workingKey, a.key, reason: 'workingKey 不因一次失败被清空');
    });

    test('空列表 / 无状态时保持原顺序', () {
      expect(orderProxyIps(const <ProxyIp>[], const ProxyIpState()), isEmpty);
      expect(
        orderProxyIps(<ProxyIp>[a, b, c], const ProxyIpState())
            .map((e) => e.key)
            .toList(),
        <String>[a.key, b.key, c.key],
      );
    });
  });

  group('ProxyIpState · 持久化', () {
    test('encode/decode 往返保真（stats + workingKey）', () {
      final state = const ProxyIpState()
          .recordSuccess('1.1.1.1:443', nowMs: 111)
          .recordFailure('2.2.2.2:443', nowMs: 222);

      final restored = ProxyIpState.decode(state.encode());

      expect(restored.workingKey, '1.1.1.1:443');
      expect(restored.statOf('1.1.1.1:443').ok, 1);
      expect(restored.statOf('1.1.1.1:443').lastOkAt, 111);
      expect(restored.statOf('2.2.2.2:443').fail, 1);
      expect(restored.statOf('2.2.2.2:443').lastFailAt, 222);
    });

    test('坏 JSON / 空串 → 空状态，不抛异常（抓取不该被状态文件搞挂）', () {
      expect(ProxyIpState.decode('{半截').stats, isEmpty);
      expect(ProxyIpState.decode('').stats, isEmpty);
      expect(ProxyIpState.decode('[]').stats, isEmpty);
    });
  });
}
