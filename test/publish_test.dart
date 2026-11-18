import 'dart:convert';

import 'package:cytest/data/node_template.dart';
import 'package:cytest/data/publish.dart';
import 'package:cytest/data/vless.dart';
import 'package:flutter_test/flutter_test.dart';

const _template =
    'vless://8b1c2d3e-4f5a-4b6c-8d9e-0a1b2c3d4e5f@1.2.3.4:443'
    '?encryption=none&security=tls&type=ws&host=cdn.example.com'
    '&path=%2F1.2.3.4:443&fp=chrome#%E6%A8%A1%E7%89%88';

void main() {
  group('buildPublish · 模板替换与产物生成', () {
    test('按选中顺序替换 host:port，并生成 base64 订阅', () {
      const targets = ['9.9.9.9:1111', '8.8.8.8:2222'];
      final b = buildPublish(template: _template, targets: targets);

      expect(b.links, hasLength(2));
      expect(b.links[0], contains('@9.9.9.9:1111?'));
      expect(b.links[1], contains('@8.8.8.8:2222?'));
      // 模板里的 uuid / 参数 / 备注不能丢
      expect(b.links[0], contains('8b1c2d3e-4f5a-4b6c-8d9e-0a1b2c3d4e5f'));
      expect(b.links[0], contains('security=tls'));
      expect(b.links[0], contains('#%E6%A8%A1%E7%89%88'));

      final decoded = utf8.decode(base64Decode(b.subscription));
      expect(decoded, b.links.join('\n'));
      // 订阅必须是标准 base64，不能是明文
      expect(b.subscription.contains('vless://'), isFalse);
    });

    test('mihomo YAML 用选中节点，不用模板里的原始 host:port', () {
      const targets = ['9.9.9.9:1111'];
      final b = buildPublish(template: _template, targets: targets);

      expect(b.yaml, contains('server: 9.9.9.9'));
      expect(b.yaml, contains('port: 1111'));
      expect(b.yaml, isNot(contains('server: 1.2.3.4')));
      expect(b.yaml, contains('type: vless'));
      expect(b.yaml, contains('uuid: 8b1c2d3e-4f5a-4b6c-8d9e-0a1b2c3d4e5f'));
      expect(b.yaml, contains('proxies:'));
      expect(b.yaml, contains('proxy-groups:'));
    });

    test('模板解析出的 Vless 字段完整（remark 解码）', () {
      final v = Vless.tryParse(_template)!;
      expect(v.uuid, '8b1c2d3e-4f5a-4b6c-8d9e-0a1b2c3d4e5f');
      expect(v.host, '1.2.3.4');
      expect(v.port, 443);
      expect(v.security, 'tls');
      expect(v.network, 'ws');
      expect(v.name, '模版');
    });

    test('四类失败都给中文原因，不静默产出空内容', () {
      expect(
        () => buildPublish(template: '', targets: const ['1.1.1.1:443']),
        throwsA(isA<PublishException>()
            .having((e) => e.message, 'message', contains('先填入'))),
      );
      expect(
        () => buildPublish(template: 'not-a-link', targets: const ['1.1.1.1:443']),
        throwsA(isA<PublishException>()
            .having((e) => e.message, 'message', contains('格式不对'))),
      );
      expect(hasSlot('not-a-link'), isFalse);
      expect(
        () => buildPublish(template: _template, targets: const []),
        throwsA(isA<PublishException>()
            .having((e) => e.message, 'message', contains('没有选中'))),
      );
    });
  });
}
