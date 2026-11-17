import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/censys_fetch.dart';
import 'package:cytest/data/censys_http.dart';
import 'package:cytest/data/censys_native.dart';

const _json = '{"results":{"total_hits":84,"hits":[]},"status":"ok"}';

/// 挑战页：服务端通了，但要求过验证（Cookie 无效/过期）。
const _challenge = CensysHttpResult(
  statusCode: 200,
  contentType: 'text/html',
  bytes: 3021,
  head: '<!doctype html>',
  error: 'HTTP 200 · text/html · 3021 字节 —— 这是人机验证页，需要过一次验证',
);

/// 压根没连上（TLS 指纹 / 超时 / 无出口）：没有状态码。
const _unreachable = CensysHttpResult(error: 'TLS 握手失败：Connection reset by peer');

/// 通了但返回的不是搜索结果（例如 CQL 语法错）。
const _apiError = CensysHttpResult(
  statusCode: 400,
  contentType: 'application/json',
  bytes: 64,
  head: '{"status":"error"}',
  error: 'HTTP 400 · application/json · 64 字节（不是 Censys 搜索结果）',
);

void main() {
  group('shouldTryHttp · 什么时候值得先试纯 HTTP', () {
    test('没有 Cookie → 不试（必然拿挑战页，白等一次）', () {
      expect(shouldTryHttp(cookie: '', httpDisabled: false), isFalse);
      expect(shouldTryHttp(cookie: '   ', httpDisabled: false), isFalse);
    });

    test('有 Cookie 且本会话没禁用 → 试', () {
      expect(shouldTryHttp(cookie: '_fs_ch_st_x=1', httpDisabled: false), isTrue);
    });

    test('已判定「HTTP 用不上」→ 一律不试，哪怕 Cookie 还在', () {
      expect(shouldTryHttp(cookie: '_fs_ch_st_x=1', httpDisabled: true), isFalse);
    });
  });

  group('judgeHttpFailure · 失败性质决定后续动作（最容易判错的一步）', () {
    test('成功 → 无需处置', () {
      const ok = CensysHttpResult(json: _json, statusCode: 200, contentType: 'application/json');
      expect(judgeHttpFailure(ok), isNull);
    });

    test('没有状态码（连接/握手/超时）→ 禁用快路径，不要反复重试', () {
      expect(judgeHttpFailure(_unreachable), CensysFallback.disableHttp);
    });

    test('拿到 HTML 挑战页 → 清 Cookie', () {
      expect(judgeHttpFailure(_challenge), CensysFallback.clearCookie);
    });

    test('401 / 403 → 清 Cookie', () {
      for (final code in <int>[401, 403]) {
        final r = CensysHttpResult(statusCode: code, contentType: 'text/plain');
        expect(judgeHttpFailure(r), CensysFallback.clearCookie, reason: '$code');
      }
    });

    test('接口返回错误 JSON（如 CQL 语法错）→ 保持现状，改查询后仍值得试', () {
      expect(judgeHttpFailure(_apiError), isNull);
    });

    test('5xx 不当作 Cookie 问题（服务端故障，与身份无关）', () {
      const r = CensysHttpResult(statusCode: 502, contentType: 'text/html');
      // text/html 优先判为挑战页 → 清 Cookie 是安全的（下次重新拿）
      expect(judgeHttpFailure(r), CensysFallback.clearCookie);
    });
  });

  group('CensysFetchPlan · 脏标记只反映真实变更', () {
    test('同值写入不标脏（避免每次抓取都写一次设置）', () {
      final plan = CensysFetchPlan(cookie: 'a=1');
      plan.setCookie('a=1');
      expect(plan.cookieDirty, isFalse);
      plan.setCookie('a=2');
      expect(plan.cookieDirty, isTrue);
    });

    test('首尾空白被裁掉；全空白等于清空', () {
      final plan = CensysFetchPlan(cookie: 'a=1');
      plan.setCookie('  b=2  ');
      expect(plan.cookie, 'b=2');
      plan.setCookie('   ');
      expect(plan.cookie, '');
    });

    test('clearDirty 之后不再算脏', () {
      final plan = CensysFetchPlan(cookie: 'a=1');
      plan.clearCookie();
      expect(plan.cookieDirty, isTrue);
      plan.clearDirty();
      expect(plan.cookieDirty, isFalse);
    });
  });

  group('fetchCensysOnce · 路径选择与回退', () {
    late List<String> httpCalls;
    late List<String> webviewCalls;
    late int cookieReads;

    setUp(() {
      httpCalls = <String>[];
      webviewCalls = <String>[];
      cookieReads = 0;
    });

    Future<CensysFetchOutcome> run({
      required CensysFetchPlan plan,
      CensysHttpResult? httpResult,
      String webviewResult = _json,
      String freshCookie = '',
      Object? webviewError,
      int? proxyPort,
    }) {
      return fetchCensysOnce(
        plan: plan,
        query: 'host.services.port:443',
        proxyPort: proxyPort,
        httpProbe: (q, cookie, port) async {
          httpCalls.add('$q|$cookie|$port');
          return httpResult ?? const CensysHttpResult(error: '未配置');
        },
        webviewFetch: (q, port) async {
          webviewCalls.add('$q|$port');
          if (webviewError != null) throw webviewError;
          return webviewResult;
        },
        readCookie: () async {
          cookieReads++;
          return freshCookie;
        },
      );
    }

    test('没有 Cookie → 直接走 WebView，一次 HTTP 都不发', () async {
      final plan = CensysFetchPlan();
      final out = await run(plan: plan, freshCookie: '_fs_ch_st_x=1');

      expect(httpCalls, isEmpty);
      expect(webviewCalls, hasLength(1));
      expect(out.path, CensysPath.webview);
      expect(out.httpNote, isNull, reason: '没试过 HTTP 就没有「未命中原因」');
      expect(plan.cookie, '_fs_ch_st_x=1', reason: '抓到后要收 Cookie，下次才能走快路径');
      expect(plan.cookieDirty, isTrue);
    });

    test('本会话已禁用 HTTP → 即使有 Cookie 也直接走 WebView', () async {
      final plan = CensysFetchPlan(cookie: 'a=1', httpDisabled: true);
      final out = await run(plan: plan);

      expect(httpCalls, isEmpty);
      expect(out.path, CensysPath.webview);
    });

    test('有 Cookie 且 HTTP 命中 → 不启动 WebView（快路径的全部价值）', () async {
      final plan = CensysFetchPlan(cookie: 'a=1');
      final out = await run(
        plan: plan,
        httpResult: const CensysHttpResult(
          json: _json,
          statusCode: 200,
          contentType: 'application/json',
        ),
      );

      expect(httpCalls, hasLength(1));
      expect(webviewCalls, isEmpty);
      expect(out.path, CensysPath.http);
      expect(out.viaHttp, isTrue);
      expect(out.json, _json);
      expect(plan.cookie, 'a=1', reason: '没走 WebView 就不该动 Cookie');
      expect(plan.cookieDirty, isFalse);
      expect(cookieReads, 0);
    });

    test('Cookie 过期（挑战页）→ 清 Cookie 并回退 WebView，新 Cookie 回写', () async {
      final plan = CensysFetchPlan(cookie: 'stale=1');
      final out = await run(
        plan: plan,
        httpResult: _challenge,
        freshCookie: '_fs_ch_st_fresh=1',
      );

      expect(out.path, CensysPath.webview);
      expect(out.httpNote, contains('人机验证页'), reason: '状态串要能解释为什么回退');
      expect(webviewCalls, hasLength(1));
      expect(plan.cookie, '_fs_ch_st_fresh=1');
      expect(plan.httpDisabled, isFalse, reason: '挑战可解，不该禁用快路径');
    });

    test('请求根本没发出去 → 禁用快路径，但 WebView 照样兜住', () async {
      final plan = CensysFetchPlan(cookie: 'a=1');
      final out = await run(plan: plan, httpResult: _unreachable, freshCookie: 'b=2');

      expect(out.path, CensysPath.webview);
      expect(plan.httpDisabled, isTrue, reason: 'TLS 层挡住的请求重试只会重复等待');
      expect(out.httpNote, contains('TLS'));
      expect(plan.cookie, 'b=2', reason: 'WebView 拿到的 Cookie 仍然有效，要留着');
    });

    test('接口返回错误 JSON → 既不清 Cookie 也不禁用（查询本身的问题）', () async {
      final plan = CensysFetchPlan(cookie: 'a=1');
      await run(plan: plan, httpResult: _apiError);

      expect(plan.cookie, 'a=1');
      expect(plan.httpDisabled, isFalse);
      expect(plan.cookieDirty, isFalse);
    });

    test('WebView 也失败 → 异常原样上抛，但 plan 的变更必须已生效', () async {
      final plan = CensysFetchPlan(cookie: 'stale=1');

      await expectLater(
        run(
          plan: plan,
          httpResult: _challenge,
          webviewError: const CensysNativeException('WebView 抓取超时（25s）'),
        ),
        throwsA(isA<CensysNativeException>()),
      );
      expect(plan.cookie, '', reason: '过期 Cookie 已被清掉，调用方要照常落盘');
      expect(plan.cookieDirty, isTrue);
    });

    test('读不到 Cookie（空串）→ 保留原值，不把有效 Cookie 抹掉', () async {
      final plan = CensysFetchPlan(cookie: 'a=1');
      await run(plan: plan, httpResult: _unreachable, freshCookie: '');

      expect(plan.cookie, 'a=1');
      expect(plan.cookieDirty, isFalse);
    });

    test('连续两次未命中 → 本会话停手（否则每次抓取都白等，且永不收敛）', () async {
      final plan = CensysFetchPlan(cookie: 'a=1');

      await run(plan: plan, httpResult: _challenge, freshCookie: 'b=2');
      expect(plan.httpDisabled, isFalse, reason: '第一次失败还值得再给一次机会');

      await run(plan: plan, httpResult: _challenge, freshCookie: 'c=3');
      expect(plan.httpDisabled, isTrue);
      expect(plan.cookie, 'c=3', reason: '停手只针对快路径，Cookie 仍要保留给下次启动');
      expect(
        shouldTryHttp(cookie: plan.cookie, httpDisabled: plan.httpDisabled),
        isFalse,
      );
    });

    test('query 与 proxyPort 原样透传给两条通道（不串参、不丢代理）', () async {
      final plan = CensysFetchPlan(cookie: 'a=1');
      await run(plan: plan, httpResult: _challenge, proxyPort: 20000, freshCookie: 'x=1');

      expect(httpCalls.single, 'host.services.port:443|a=1|20000');
      expect(webviewCalls.single, 'host.services.port:443|20000');
    });
  });
}