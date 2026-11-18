import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/candidates.dart';

void main() {
  group('extractTargets · Censys JSON', () {
    test('从 results.hits[].host.ip / port 提取并去重保序', () {
      const json = '''
      {
        "results": {
          "total_hits": 3,
          "hits": [
            {"host": {"ip": "1.1.1.1", "port": 443}},
            {"host": {"ip": "2.2.2.2", "port": 8443}},
            {"host": {"ip": "1.1.1.1", "port": 443}}
          ]
        }
      }
      ''';
      expect(extractTargets(json), ['1.1.1.1:443', '2.2.2.2:8443']);
    });

    test('host.port 缺失时回退到 services[].port', () {
      const json =
          '{"results":{"hits":[{"host":{"ip":"3.3.3.3","services":[{"port":80},{"port":8080}]}}]}}';
      expect(extractTargets(json), ['3.3.3.3:80', '3.3.3.3:8080']);
    });

    test('兼容 host.host.ip 嵌套结构（pipeline.go 的解析口径）', () {
      const json =
          '{"results":{"hits":[{"host":{"host":{"ip":"7.7.7.7","services":[{"port":25443}]}}}]}}';
      expect(extractTargets(json), ['7.7.7.7:25443']);
    });

    test('脏数据：非法端口 / 缺 ip / 非对象 hit 全部跳过', () {
      const json = '''
      {"results":{"hits":[
        {"host":{"ip":"4.4.4.4","port":70000}},
        {"host":{"ip":"","port":443}},
        {"host":{"ip":"5.5.5.5"}},
        "oops",
        {"host":{"ip":"6.6.6.6","port":"2053"}}
      ]}}
      ''';
      expect(extractTargets(json), ['6.6.6.6:2053']);
    });

    test('JSON 语法错误返回空列表且不抛异常', () {
      expect(extractTargets('{"results": {"hits": [oops'), isEmpty);
    });
  });

  group('extractTargets · result.csv', () {
    test('跳过表头，按前两列提取 ip:port', () {
      const csv = 'IP,Port,Latency (ms),Speed (MiB/s),Reason\n'
          '1.1.1.1,443,12,8.50,\n'
          '2.2.2.2,8443,40,1.20,\n';
      expect(extractTargets(csv), ['1.1.1.1:443', '2.2.2.2:8443']);
    });

    test('无表头也能解析，注释行/空行/非法端口跳过', () {
      const csv = '# 这是注释\n'
          '\n'
          '1.1.1.1,443\n'
          'badline\n'
          '2.2.2.2, 0\n'
          '3.3.3.3, 65535,extra\n'
          '4.4.4.4,abc\n'
          '1.1.1.1,443\n';
      expect(extractTargets(csv), ['1.1.1.1:443', '3.3.3.3:65535']);
    });

    // 表头判定必须是「首列 == ip 或第二列 == port」，不能是「整行 contains ip」。
    // 用 contains 时 `proxyip,443` 这类**数据行**会被当成表头整行丢掉。
    test('含 ip 字样但不是表头的数据行必须被解析，不能当表头整行丢弃', () {
      expect(extractTargets('proxyip,443'), ['proxyip:443']);
      expect(
        extractTargets('ipcheck.example,8443\n1.1.1.1,443'),
        ['ipcheck.example:8443', '1.1.1.1:443'],
      );
    });

    test('只认真正的表头：首列 ip / 第二列 port（大小写不敏感）', () {
      expect(extractTargets('ip,port\n1.1.1.1,443'), ['1.1.1.1:443']);
      expect(extractTargets('IP,Port\n1.1.1.1,443'), ['1.1.1.1:443']);
      // 首列是 ip 的一律当表头（哪怕只有一列）
      expect(extractTargets('ip\n1.1.1.1,443'), ['1.1.1.1:443']);
    });

    test('带引号的表头同样不会变成候选（_looksLikeHeader 直接识别）', () {
      // _looksLikeHeader 内部已用 _unquote 去引号，`"IP"`/`"Port"` 会被直接
      // 判为表头；不再隐式依赖「Port 不是数字」的端口解析兜底。
      expect(
        extractTargets('"IP","Port"\n"1.1.1.1","443"'),
        ['1.1.1.1:443'],
      );

      // 上面那条**不能**证明 _unquote 真的在表头判定里生效：即使去掉 unquote，
      // `"Port"` 也会因为「不是数字」被跳过，断言照样通过。这里用「第二列是数字」
      // 的引号行做隔离探针 —— 只有 unquote 生效时它才会被整行当表头丢弃；
      // 若 unquote 被删掉，这行会变成候选 `ip:443`，本条立刻失败。
      expect(
        extractTargets('"ip","443"\n"1.1.1.1","443"'),
        ['1.1.1.1:443'],
      );
    });
  });

  group('extractTargets · 空内容', () {
    test('空串与纯空白返回空列表', () {
      expect(extractTargets(''), isEmpty);
      expect(extractTargets('   \n\t '), isEmpty);
    });
  });

  // 契约：JSON 合法但结构里没有 hits 时，必须安静返回空列表。
  // 这类响应真实存在（Censys 返回 {"code":..., "message":"..."} 之类的错误体、
  // 或分页到最后一页的 {"results":{"total_hits":0,"hits":[]}}），
  // 否则本地测试页会拿到脏候选去跑。
  group('extractTargets · 合法 JSON 但没有 hits', () {
    test('顶层是空对象 / 无 hits 键 → 空列表', () {
      expect(extractTargets('{}'), isEmpty);
      expect(extractTargets('{"code":401,"message":"unauthorized"}'), isEmpty);
    });

    test('results 存在但 hits 缺失或是空数组 → 空列表', () {
      expect(extractTargets('{"results":{"total_hits":0}}'), isEmpty);
      expect(extractTargets('{"results":{"total_hits":0,"hits":[]}}'), isEmpty);
    });

    test('hits 不是数组（类型不对）→ 空列表', () {
      expect(extractTargets('{"results":{"hits":"oops"}}'), isEmpty);
      expect(extractTargets('{"results":{"hits":{"ip":"1.1.1.1"}}}'), isEmpty);
    });

    test('顶层直接是数组时按 hits 处理；空数组 → 空列表', () {
      expect(extractTargets('[]'), isEmpty);
      expect(
        extractTargets('[{"host":{"ip":"7.7.7.7","port":8443}}]'),
        ['7.7.7.7:8443'],
      );
    });

    test('顶层 {"hits":[...]} 也被识别（无 results 包裹）', () {
      expect(
        extractTargets('{"hits":[{"host":{"ip":"8.8.8.8","port":53}}]}'),
        ['8.8.8.8:53'],
      );
    });

    test('JSON 标量（非对象/数组）开头不是 { 或 [ 时走 CSV，仍不抛异常', () {
      // 走 CSV 分支：没有逗号 → 跳过所有行 → 空列表
      expect(extractTargets('null'), isEmpty);
      expect(extractTargets('12345'), isEmpty);
    });
  });
}
