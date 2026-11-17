import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' show Cookie;

import 'package:cytest/data/censys_http.dart'
    show censysJsonOrNull, buildCookieHeader, normalizeDocumentCookie;

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

  group('censysJsonOrNull · 实测形态：HTTP 200 + 挑战页 HTML', () {
    test('真实挑战页（含 <!doctype>、CSP 脚本、Just a moment 标题）→ null', () {
      const html = '<!doctype html><html><head><meta charset="utf-8">'
          '<title>Just a moment...</title>'
          "<meta http-equiv=\"Content-Security-Policy\" "
          "content=\"default-src 'self'; script-src 'self' 'sha256-abc'\">"
          '<script>window._cf_chl_opt={cvId:"3",cRay:"8f2a"};</script>'
          '</head><body><div id="challenge-running">'
          'Checking your browser before accessing platform.censys.io.'
          '</div></body></html>';

      expect(censysJsonOrNull(html), isNull);
    });

    test('HTTP 200 但返回的是错误 JSON（无 results）→ null，不能当数据', () {
      expect(
        censysJsonOrNull('{"status":"error","message":"unauthenticated"}'),
        isNull,
      );
    });
  });

  group('buildCookieHeader · Cookie 请求头构造（最容易漏的一步）', () {
    test('空列表 → 空串（不能返回 "; "，否则服务端认为带了空 cookie）', () {
      expect(buildCookieHeader(const <Cookie>[]), '');
    });

    test('多个 cookie 用 "; " 连接，顺序按传入顺序', () {
      final header = buildCookieHeader(<Cookie>[
        Cookie(name: 'cf_clearance', value: 'abc123'),
        Cookie(name: 'PHPSESSID', value: 'xyz'),
      ]);

      expect(header, 'cf_clearance=abc123; PHPSESSID=xyz');
    });

    test('同名 cookie 后者覆盖前者（与浏览器行为一致）', () {
      final header = buildCookieHeader(<Cookie>[
        Cookie(name: 'a', value: '1'),
        Cookie(name: 'a', value: '2'),
      ]);

      expect(header, 'a=2');
    });

    test('name 为空/空白的项被跳过', () {
      final header = buildCookieHeader(<Cookie>[
        Cookie(name: '  ', value: 'ignored'),
        Cookie(name: 'a', value: '1'),
      ]);

      expect(header, 'a=1');
    });

    test('value 为 null 时保留 "name="（有些服务端要求该键出现）', () {
      final header = buildCookieHeader(<Cookie>[Cookie(name: 'flag')]);

      expect(header, 'flag=');
    });
  });

  group('normalizeDocumentCookie · CookieManager 不可用时的兜底', () {
    test('去掉空白与结尾分号，保留 key=value', () {
      expect(normalizeDocumentCookie(' a=1;  b=2; '), 'a=1; b=2');
    });

    test('空串 / 只有分号 → 空串', () {
      expect(normalizeDocumentCookie(''), '');
      expect(normalizeDocumentCookie(' ; ; '), '');
    });

    test('没有 "=" 的片段被丢掉（不是合法 cookie）', () {
      expect(normalizeDocumentCookie('a=1; garbage; b=2'), 'a=1; b=2');
    });
  });
}
