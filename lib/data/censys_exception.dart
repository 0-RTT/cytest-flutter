/// 抓取失败的原因，`toString()` 直接可展示给用户。
///
/// 单独一个文件：Android（MethodChannel）与 Windows（WebView2）两套实现都要抛它，
/// 放在任一实现里都会形成循环 import。
class CensysNativeException implements Exception {
  const CensysNativeException(this.message, {this.details = const {}});

  final String message;

  /// 诊断信息（proxyMode / sawChallenge / preview / snippet）。
  final Map<Object?, Object?> details;

  @override
  String toString() => message;
}
