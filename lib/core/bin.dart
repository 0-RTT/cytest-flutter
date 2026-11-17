import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel, rootBundle;

/// 原生二进制访问。
///
/// Android 上不能直接执行 assets 里的文件（SELinux 会拒绝），
/// 因此 pipeline / xray 以 `lib*.so` 形式打进 jniLibs，
/// 由系统解压到 nativeLibraryDir 并获得可执行权限。
class Bins {
  Bins._();

  static const _channel = MethodChannel('cytest/native');
  static String? _nativeDir;

  /// 返回可执行的二进制路径。
  /// [name] 为 'pipeline' 或 'xray'。
  static Future<String> path(String name) async {
    if (Platform.isAndroid) {
      _nativeDir ??= await _channel.invokeMethod<String>('nativeLibraryDir');
      final dir = _nativeDir;
      if (dir == null || dir.isEmpty) {
        throw Exception('拿不到 nativeLibraryDir');
      }
      final file = File('$dir/lib$name.so');
      if (!await file.exists()) {
        throw Exception('未找到 $dir/lib$name.so（打包时未放入 jniLibs？）');
      }
      return file.path;
    }

    // 桌面 / 测试环境：与旧逻辑一致，从 assets 释放到可执行目录
    final dir = Directory('${Directory.systemTemp.path}/cytest-bin');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File('${dir.path}/$name');
    if (!await file.exists()) {
      final data = await rootBundle.load('assets/$name');
      await file.writeAsBytes(data.buffer.asUint8List(0, data.lengthInBytes));
      await Process.run('chmod', ['755', file.path]);
    }
    return file.path;
  }

  /// 远程执行用的 Linux 版引擎仍走 assets（不上 jniLibs，避免三份二进制）。
  static Future<List<int>> loadLinuxPipeline() async {
    final data = await rootBundle.load('assets/pipeline-linux');
    return data.buffer.asUint8List(0, data.lengthInBytes);
  }
}
