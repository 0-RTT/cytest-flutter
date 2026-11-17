import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/ui/pages/fetch_page.dart' show censysJsonOrNull;

/// 直连 `/api/search` 时，WebView `innerText` 的三种真实形态 + 判定。
void main() {
  group('censysJsonOrNull · 直连数据的唯一判据', () {
    test('真数据：含 results 的 JSON → 返回文本（两侧空白被 trim）', () {
      const raw = '  {"results":{"total_hits":84,"hits":[]},"status":"ok"}  ';

      final parsed = censysJsonOrNull(raw);

      expect(parsed, isNotNull);
      expect(parsed!.startsWith('{'), isTrue);
      expect(parsed.endsWith('}'), isTrue, reason: '不能把用户不可见的空白带进 payload');
      expect(jsonDecode(parsed), containsPair('status', 'ok'));
    });

    test('CDN 挑战页（HTML）→ null，必须走 fallback', () {
      const html = '<!DOCTYPE html><html><head><title>Just a moment...</title>'
          '</head><body>Checking your browser</body></html>';

      expect(censysJsonOrNull(html), isNull);
    });

    test('空内容 / 纯空白 → null', () {
      expect(censysJsonOrNull(''), isNull);
      expect(censysJsonOrNull('   \n\t '), isNull);
    });

    test('JSON 但没有 results（错误响应体）→ null，不能当数据用', () {
      expect(censysJsonOrNull('{"status":"error","message":"unauthorized"}'),
          isNull);
      expect(censysJsonOrNull('{"results":null}'), isNull);
    });

    test('被截断的 JSON → null，不抛异常', () {
      expect(censysJsonOrNull('{"results":{"total_hits":84,"hit'), isNull);
    });

    test('JSON 数组（不是对象）→ null', () {
      expect(censysJsonOrNull('[{"host":{"ip":"1.1.1.1"}}]'), isNull);
    });
  });
}
