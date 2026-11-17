import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/censys_native.dart';

/// `cytest/censys` channel 的 Dart 侧：参数透传 + 错误翻译。
///
/// 原生侧的行为（挑战检测 / 分片读 / 代理）只能在真机验，但「Dart 有没有把
/// query / proxyPort / timeoutMs 正确传下去」以及「原生错误有没有被翻译成
/// 可读文案」这两件事完全可以单测钉住 —— 它们是最容易在重构里悄悄坏掉的部分。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('cytest/censys');
  late List<MethodCall> calls;

  /// 让原生侧按 query 返回不同结果，模拟三种真实情况。
  void mockChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method != 'fetchSearch') return null;
      final args = (call.arguments as Map).cast<String, Object?>();
      switch (args['query']) {
        case 'dial-fail':
          throw PlatformException(
            code: 'fetch_failed',
            message: 'WebView 抓取超时（25s），一直停在人机验证页（Fastly 挑战未通过）',
            details: <String, Object?>{
              'proxyMode': 'http://127.0.0.1:20000',
              'sawChallenge': true,
              'preview': '<!doctype html>...',
            },
          );
        case 'html-body':
          return '<!doctype html><html><body>challenge</body></html>';
        default:
          return '{"results":{"total_hits":84,"hits":[]},"status":"ok"}';
      }
    });
  }

  setUp(() {
    calls = <MethodCall>[];
    mockChannel();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('fetchCensysSearch · 参数透传', () {
    test('query / proxyPort / timeoutMs 原样传到原生', () async {
      final json = await fetchCensysSearch(
        query: 'host.services.port:443',
        proxyPort: 20000,
        timeout: const Duration(seconds: 12),
      );

      expect(json, contains('"results"'));
      final args = (calls.single.arguments as Map).cast<String, Object?>();
      expect(args['query'], 'host.services.port:443');
      expect(args['proxyPort'], 20000);
      expect(args['timeoutMs'], 12000);
    });

    test('没有 proxyPort 时传 null（原生侧据此直连）', () async {
      await fetchCensysSearch(query: 'x');

      final args = (calls.single.arguments as Map).cast<String, Object?>();
      expect(args.containsKey('proxyPort'), isTrue);
      expect(args['proxyPort'], isNull);
      expect(args['timeoutMs'], 25000, reason: '默认 25s');
    });
  });

  group('fetchCensysSearch · 错误翻译', () {
    test('PlatformException → CensysNativeException，message 可直接展示', () async {
      await expectLater(
        fetchCensysSearch(query: 'dial-fail', proxyPort: 20000),
        throwsA(
          isA<CensysNativeException>()
              .having((e) => e.message, 'message', contains('Fastly'))
              .having((e) => e.details['sawChallenge'], 'sawChallenge', isTrue)
              .having((e) => e.details['proxyMode'], 'proxyMode',
                  'http://127.0.0.1:20000'),
        ),
      );
    });

    test('原生返回 HTML（挑战页）→ 抛「不是 Censys 搜索结果」，不把 HTML 当数据', () async {
      await expectLater(
        fetchCensysSearch(query: 'html-body'),
        throwsA(
          isA<CensysNativeException>()
              .having((e) => e.message, 'message', contains('不是 Censys 搜索结果')),
        ),
      );
    });

    test('空返回同样判失败（原生返回 null）', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);

      await expectLater(
        fetchCensysSearch(query: 'empty'),
        throwsA(isA<CensysNativeException>()),
      );
    });
  });
}
