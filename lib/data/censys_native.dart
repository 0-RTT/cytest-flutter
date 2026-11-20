import 'package:flutter/services.dart';

import 'censys_json.dart' show censysJsonOrNull;

/// 原生 WebView 抓取的失败原因，`toString()` 直接可展示给用户。
class CensysNativeException implements Exception {
  const CensysNativeException(this.message, {this.details = const {}});

  final String message;

  /// 原生侧回传的诊断信息（proxyMode / sawChallenge / preview）。
  final Map<Object?, Object?> details;

  @override
  String toString() => message;
}

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
    // 原生侧已经把「是不是挑战页」判断过了；走到这里说明返回内容异常
    throw const CensysNativeException('原生 WebView 返回的不是 Censys 搜索结果');
  }
  return json;
}
