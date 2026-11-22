import 'dart:io';

import 'package:flutter/services.dart';

import 'censys_exception.dart';
import 'censys_json.dart' show censysJsonOrNull;
import 'censys_windows.dart';

// 异常类在 censys_exception.dart：两套平台实现都要抛它，放这里会循环依赖。
export 'censys_exception.dart';

/// 与 `MainActivity` 的 `cytest/censys` channel 对应。
const MethodChannel _channel = MethodChannel('cytest/censys');

/// 用**原生 WebView** 抓 Censys 搜索结果，返回 JSON 文本。
///
/// 为什么不是纯 HTTP / 插件 WebView：站点是 Fastly 分级放行，纯 HTTP 在 TLS 层
/// 就被拒（实测带齐 27 个浏览器头仍返回挑战页）；插件的 headless 实现有指纹缺陷。
/// 原生 `WebView` 不 attach 也能过挑战 —— 用它代替纯 HTTP 抓取的根本原因。
///
/// [proxyPort] 为 Xray 本地混合口；为空表示直连（大概率被挑战）。
/// [timeout] 总超时，原生侧默认 25s。
///
/// 抛 [CensysNativeException]：超时 / 挑战未过 / 代理不支持 / 返回不是搜索结果。
Future<String> fetchCensysSearch({
  required String query,
  int? proxyPort,
  Duration timeout = const Duration(seconds: 25),
}) async {
  // Windows 走进程内 Headless WebView2（没有原生通道）。
  //
  // 但 `flutter test` 本身就跑在 Windows 上：测试里必须继续走 MethodChannel，
  // 否则 mock 的通道永远收不到调用，所有用例都会「静默走真浏览器」。
  // FLUTTER_TEST 是 flutter_test 注入的环境变量，用它区分「真机」与「测试进程」。
  final underTest = Platform.environment['FLUTTER_TEST'] == 'true';
  if (Platform.isWindows && !underTest) {
    return fetchCensysSearchWindows(
      query: query,
      proxyPort: proxyPort,
      timeout: timeout,
    );
  }

  final String? text;
  try {
    text = await _channel.invokeMethod<String>('fetchSearch', <String, Object?>{
      'query': query,
      'proxyPort': proxyPort,
      'timeoutMs': timeout.inMilliseconds,
    });
  } on MissingPluginException {
    throw const CensysNativeException('当前平台没有实现原生抓取（仅 Android 支持）');
  } on PlatformException catch (e) {
    throw CensysNativeException(
      e.message ?? '原生抓取失败（${e.code}）',
      details: e.details is Map ? e.details as Map<Object?, Object?> : const {},
    );
  }

  final json = censysJsonOrNull(text ?? '');
  if (json == null) {
    // 原生侧已经把「是不是挑战页」判断过了；走到这里说明返回内容异常。
    // 带上开头几十个字符：如果是 CQL 语法错误，服务端的报错原文就在这里
    // （不带的话只能看到一句「不是搜索结果」，完全无从判断）。
    final snippet = (text ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');
    final hint = snippet.isEmpty
        ? '响应为空'
        : snippet.length > 160
            ? '${snippet.substring(0, 160)}…'
            : snippet;
    throw CensysNativeException(
      hint.isEmpty
          ? '原生 WebView 返回的不是 Censys 搜索结果（响应为空）'
          : '原生 WebView 返回的不是 Censys 搜索结果（响应开头：$hint）',
      details: <Object?, Object?>{'snippet': hint},
    );
  }
  return json;
}
