import 'package:flutter/services.dart';

/// 系统文件选择器（Android SAF）的失败原因，`toString()` 直接可展示给用户。
class FilePickException implements Exception {
  const FilePickException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 与 `MainActivity.kt` 里的 `cytest/file` channel 对应。
const MethodChannel _channel = MethodChannel('cytest/file');

/// 调系统文件选择器读一个 UTF-8 文本文件。
///
/// - 返回 `null`：用户取消（不是错误，调用方静默处理）；
/// - 抛 [FilePickException]：打不开选择器 / 读失败 / 文件过大（>5MB），带中文原因；
/// - 非 Android 平台：抛 [FilePickException]（当前只有 Android 侧实现了 channel）。
///
/// 为什么走自建 MethodChannel 而不加 `file_picker`：AGP 9 兼容性未知，
/// 而 SAF 是系统 API，一个 Intent 就够（见 MainActivity 注释）。
Future<String?> pickTextFile() async {
  try {
    return await _channel.invokeMethod<String>('pickTextFile');
  } on PlatformException catch (e) {
    throw FilePickException(_humanize(e));
  } on MissingPluginException {
    throw const FilePickException('当前平台没有实现文件选择器（仅 Android 支持）');
  }
}

/// 文件夹里的一个候选文件（只用于界面展示，选中后由原生侧复制）。
class KeyFileCandidate {
  const KeyFileCandidate({
    required this.name,
    required this.size,
    required this.uri,
  });

  final String name;

  /// 字节数，-1 = 未知（某些 provider 不给大小）。
  final int size;

  /// `content://...` 文档 URI（选中后交给 [importKeyUri]）。
  final String uri;
}

/// 选一个 SSH 私钥**文件夹**，返回里面的文件列表（用户取消返回 null）。
///
/// 为什么不是「直接选文件」：Android 17 的文件选择器按 MIME 过滤，无后缀的
/// 密钥（id_rsa / id_ed25519）算不出类型，连 `*/*` 也显示不出来 —— 用户看到
/// 「文件夹能进，里面空空」。改成拿目录的读权限，由应用自己列子项，
/// 全程不经过 MIME 判断。
Future<List<KeyFileCandidate>?> pickKeyFolder() async {
  try {
    final raw = await _channel.invokeListMethod<dynamic>('pickKeyFolder');
    if (raw == null) return null;
    return [
      for (final item in raw)
        if (item is Map)
          KeyFileCandidate(
            name: '${item['name'] ?? ''}',
            size: (item['size'] as num?)?.toInt() ?? -1,
            uri: '${item['uri'] ?? ''}',
          ),
    ];
  } on PlatformException catch (e) {
    throw FilePickException(_humanize(e));
  } on MissingPluginException {
    throw const FilePickException('当前平台没有实现文件选择器（仅 Android 支持）');
  }
}

/// 把 [KeyFileCandidate.uri] 指向的文件复制到应用私有目录，返回绝对路径。
Future<String?> importKeyUri(String uri) async {
  try {
    return await _channel.invokeMethod<String>('importKeyUri', {'uri': uri});
  } on PlatformException catch (e) {
    throw FilePickException(_humanize(e));
  } on MissingPluginException {
    throw const FilePickException('当前平台没有实现文件选择器（仅 Android 支持）');
  }
}

/// 选一个 SSH 私钥文件（单文件通道，部分机型可用）。
///
/// 与 [pickTextFile] 分开的原因：那个把 MIME 限定在 text/csv 一类，而私钥常常
/// **没有后缀**（id_rsa / id_ed25519），SAF 报不出类型 → 在选择器里直接变灰。
/// 这里用 `*/*` 不做过滤，并且由原生侧把内容复制到应用目录后返回**副本路径**
/// （`content://` 不能交给 dartssh2 当文件路径，也不能重复读）。
///
/// 返回 `null` = 用户取消；抛 [FilePickException] = 选择或复制失败。
Future<String?> pickKeyFile() async {
  try {
    return await _channel.invokeMethod<String>('pickKeyFile');
  } on PlatformException catch (e) {
    throw FilePickException(_humanize(e));
  } on MissingPluginException {
    throw const FilePickException('当前平台没有实现文件选择器（仅 Android 支持）');
  }
}

String _humanize(PlatformException e) {
  final message = e.message;
  if (message != null && message.isNotEmpty) return message;
  return switch (e.code) {
    'too_large' => '文件过大（上限 5MB）',
    'read_failed' => '读取文件失败',
    'no_picker' => '无法打开系统文件选择器',
    'busy' => '已有一个文件选择器打开，请先完成它',
    _ => '选择文件失败（${e.code}）',
  };
}
