import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/mihomo.dart';
import 'package:cytest/data/node_template.dart';
import 'package:cytest/data/pipeline.dart';
import 'package:cytest/data/vless.dart';

const _sample = 'vless://11111111-2222-3333-4444-555555555555@example.com:443'
    '?type=ws&security=tls&sni=example.com&host=example.com'
    '&path=%2F1.2.3.4%3A443%3Fed%3D2048&alpn=h2%2Chttp%2F1.1&fp=chrome#%E6%B5%8B%E8%AF%95';

void main() {
  group('Vless 解析', () {
    test('标准 ws + tls 链接', () {
      final v = Vless.tryParse(_sample);
      expect(v, isNotNull);
      expect(v!.uuid, '11111111-2222-3333-4444-555555555555');
      expect(v.host, 'example.com');
      expect(v.port, 443);
      expect(v.network, 'ws');
      expect(v.security, 'tls');
      expect(v.wsPath, '/1.2.3.4:443?ed=2048');
      expect(v.name, '测试');
    });

    test('xhttp 模式解析 mode', () {
      final v = Vless.tryParse(
        'vless://uuid@1.2.3.4:443?type=xhttp&mode=stream-one&security=tls'
        '&path=%2F104.202.107.180%3A9443&sni=x.example.com',
      );
      expect(v, isNotNull);
      expect(v!.network, 'xhttp');
      expect(v.mode, 'stream-one');
      expect(v.wsPath, '/104.202.107.180:9443');
    });

    test('拒绝非法链接', () {
      expect(Vless.tryParse(''), isNull);
      expect(Vless.tryParse('https://example.com'), isNull);
      expect(Vless.tryParse('vless://@example.com:443'), isNull);
      expect(Vless.tryParse('vless://uuid@example.com'), isNull);
    });
  });

  group('proxyip 路径替换', () {
    test('提取 ip:port', () {
      expect(pathProxyIp('/1.2.3.4:443?ed=2048'), '1.2.3.4:443');
      expect(pathProxyIp('/no-ip'), isNull);
    });

    test('替换保留查询后缀', () {
      expect(
        replacePathIp(
            '/1.2.3.4:443?ed=2048', const ProxyIp('104.16.0.1', 2053)),
        '/104.16.0.1:2053?ed=2048',
      );
      expect(
        replacePathIp('/no-ip', const ProxyIp('1.1.1.1', 443)),
        '/no-ip',
      );
    });
  });

  group('proxyip CSV', () {
    test('去重与脏行', () {
      final list = parseProxyCsv('''
# 注释
104.16.0.1:443
104.17.0.1:2053,120,18.30
104.16.0.1:443

bad-line
''');
      expect(list.length, 2);
      expect(list[0].key, '104.16.0.1:443');
      expect(list[1].port, 2053);
    });
  });

  group('Xray 配置', () {
    test('结构对齐桌面端', () {
      final v = Vless.tryParse(_sample)!;
      final cfg = buildXrayConfig(v, 20001);

      final inbounds = cfg['inbounds'] as List;
      expect(inbounds.length, 1);
      expect((inbounds.first as Map)['port'], 20001);
      expect((inbounds.first as Map)['protocol'], 'mixed');

      final outbounds = cfg['outbounds'] as List;
      expect(outbounds.length, 3);
      final proxy = outbounds.first as Map;
      expect(proxy['protocol'], 'vless');

      final stream = proxy['streamSettings'] as Map;
      expect(stream['network'], 'ws');
      expect(stream['security'], 'tls');
      expect((stream['wsSettings'] as Map)['path'], '/1.2.3.4:443?ed=2048');
      expect((stream['tlsSettings'] as Map)['serverName'], 'example.com');
    });

    test('tcp + none 不产生 ws/tls 段', () {
      final v = Vless.tryParse('vless://u@h:443?type=tcp&security=none')!;
      final json = xrayConfigJson(v, 20002);
      expect(json.contains('wsSettings'), isFalse);
      expect(json.contains('tlsSettings'), isFalse);
    });
  });

  group('订阅与模板', () {
    test('槽位识别与替换', () {
      expect(hasSlot('vless://uuid@1.1.1.1:443?type=xhttp'), isTrue);
      expect(hasSlot('vless://uuid@host?type=tcp'), isFalse);
      expect(hasSlot('not-a-link'), isFalse);
      expect(
        bindLink('vless://u@h:1?x=1', '1.2.3.4:9'),
        'vless://u@1.2.3.4:9?x=1',
      );
    });

    test('展开模板', () {
      final nodes = expandTemplate(
        'vless://u@1.1.1.1:443?type=xhttp&path=/x#模板',
        ['81.70.132.81:443', '43.139.240.138:8443'],
      );
      expect(nodes.length, 2);
      expect(nodes.first, 'vless://u@81.70.132.81:443?type=xhttp&path=/x#模板');
    });

    test('订阅为 base64 多行', () {
      final nodes = ['vless://a', 'vless://b'];
      final decoded = utf8.decode(base64Decode(subscription(nodes)));
      expect(decoded, 'vless://a\nvless://b');
    });
  });

  group('mihomo', () {
    test('生成 proxies 与分组（逐条解析已展开链接）', () {
      final links = expandTemplate(
        'vless://uuid-1@1.1.1.1:443?type=xhttp&mode=stream-one'
        '&path=/104.202.107.180:9443&security=tls&sni=x.example.com&fp=chrome&alpn=h2#节点A',
        ['1.2.3.4:8443', '5.6.7.8:2053'],
      );
      final out = buildMihomoConfig(links);
      final yaml = out.yaml;

      expect(out.proxies, 2);
      expect(out.groups, 3);
      expect(out.errors, isEmpty);
      expect(yaml, contains('proxies:'));
      expect(yaml, contains('type: vless'));
      expect(yaml, contains('server: 1.2.3.4'));
      expect(yaml, contains('network: xhttp'));
      expect(yaml, contains('xhttp-opts:'));
      expect(yaml, contains('mode: stream-one'));
      // 节点名取 #备注，重名追加 (2)（与 Kotlin MihomoYaml 对齐）
      expect(yaml, contains('name: "节点A"'));
      expect(yaml, contains('"节点A (2)"'));
      expect(yaml, contains('proxy-groups:'));
      expect(yaml, contains('type: url-test'));
      expect(yaml, contains('rules:'));
      expect(yaml.contains('ws-opts:'), isFalse);
      expect('xhttp-opts:'.allMatches(yaml).length, 2);
    });
  });

  group('mihomo · 节点命名（对齐 Kotlin MihomoYaml）', () {
    test('空备注回退 节点-N（带序号，天然不重名）', () {
      final links = expandTemplate(
        'vless://u@1.1.1.1:443?type=tcp',
        ['1.2.3.4:8443', '5.6.7.8:2053'],
      );
      final yaml = buildMihomoConfig(links).yaml;
      expect(yaml, contains('  - name: "节点-1"\n'));
      expect(yaml, contains('  - name: "节点-2"\n'));
    });

    test('备注含空格与中文时按 Kotlin SAFE_PLAIN 加引号', () {
      final yaml = buildMihomoConfig(const [
        'vless://u@1.1.1.1:443?type=tcp#A',
        'vless://u@2.2.2.2:443?type=tcp#香港 01',
      ]).yaml;
      // 纯 ASCII 安全字符裸写，中文/空格加引号
      expect(yaml, contains('  - name: A\n'));
      expect(yaml, contains('  - name: "香港 01"\n'));
    });
  });

  group('PipelineCancelToken（T05：句柄 kill 取代按名匹配）', () {
    test('attach 后 cancel：进程真的被终止，句柄解绑', () async {
      final proc = await _spawnLongRunning();
      addTearDown(() => proc.kill(ProcessSignal.sigkill));
      final token = PipelineCancelToken()..attach(proc);

      expect(token.attached, isTrue);
      await token.cancel();
      expect(token.cancelled, isTrue);
      expect(token.attached, isFalse);

      // 「返回时进程已退出」：exitCode 必须已 resolve
      final code = await proc.exitCode.timeout(const Duration(seconds: 2));
      expect(code, isNotNull);
    });

    test('先 cancel 再 attach：起来就被杀，不漏杀', () async {
      final token = PipelineCancelToken();
      await token.cancel();
      expect(token.cancelled, isTrue);

      final proc = await _spawnLongRunning();
      addTearDown(() => proc.kill(ProcessSignal.sigkill));
      token.attach(proc);

      final code = await proc.exitCode.timeout(const Duration(seconds: 5));
      expect(code, isNotNull, reason: 'attach 时发现已取消，必须立刻终止');
    });

    test('cancel 幂等，未 attach 时不抛异常', () async {
      final token = PipelineCancelToken();

      await token.cancel();
      await expectLater(token.cancel(), completes);
      expect(token.cancelled, isTrue);
    });
  });
}

/// 起一个会跑很久的进程（Windows `ping -n 30` ≈ 29s；POSIX `sleep 30`）。
/// stdout/stderr 必须读走，否则子进程写满管道会阻塞。
Future<Process> _spawnLongRunning() async {
  final proc = Platform.isWindows
      ? await Process.start('ping', const <String>['-n', '30', '127.0.0.1'])
      : await Process.start('sleep', const <String>['30']);
  unawaited(proc.stdout.drain<void>());
  unawaited(proc.stderr.drain<void>());
  return proc;
}
