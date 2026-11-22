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
    if (Platform.isWindows) return _windowsPath(name);
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

  /// Windows：直接找 `name.exe`，**不从 assets 释放、也不 chmod**。
  ///
  /// 顺序：程序目录下的 `bin/`（安装包内置，最稳，杀软对 APPDATA 里的自发
  /// 可执行文件很敏感）→ `%APPDATA%/cytest/bin/`（用户手动放置）。
  ///
  /// 路径统一用正斜杠：Dart 在 Windows 上也接受 `/`，而写成 `\b`、`\c` 会被
  /// 当成转义序列（`\b` 是退格），日志里会变成乱码，排查时极易看错。
  static Future<String> _windowsPath(String name) async {
    final candidates = <String>[];
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    candidates.add('$exeDir/bin/$name.exe');

    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      candidates.add('$appData/cytest/bin/$name.exe');
    }

    for (final path in candidates) {
      if (await File(path).exists()) return path;
    }
    throw Exception(
      'Windows 版缺少 $name.exe（应放在程序目录的 bin/ 下，'
      '或 %APPDATA%/cytest/bin/）',
    );
  }

  /// 远程执行用的 Linux 版引擎仍走 assets（不上 jniLibs，避免三份二进制）。
  static Future<List<int>> loadLinuxPipeline() async {
    final data = await rootBundle.load('assets/pipeline-linux');
    return data.buffer.asUint8List(0, data.lengthInBytes);
  }
}
