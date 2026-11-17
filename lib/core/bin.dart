import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'paths.dart';

/// 把打包进 assets 的原生二进制释放到可执行目录（Android 不能直接执行 assets）。
class Bins {
  Bins._();

  static const _assets = {
    'pipeline': 'assets/pipeline',
    'xray': 'assets/xray',
  };

  static Future<File> ensure(String name) async {
    final assetPath = _assets[name];
    if (assetPath == null) {
      throw ArgumentError('未知的二进制：$name');
    }
    final dir = await Paths.bin();
    final file = File('${dir.path}/$name');
    final data = await rootBundle.load(assetPath);

    // 已存在且大小一致则跳过（与桌面端的内容指纹策略一致，但这里用大小足够：
    // 二进制随 APK 版本变化，升级安装时 APK 已变，大小通常也变）
    if (await file.exists()) {
      final st = await file.stat();
      if (st.size == data.lengthInBytes) {
        await _chmod(file.path);
        return file;
      }
    }

    if (await file.exists()) {
      await file.delete();
    }
    await file.writeAsBytes(
      data.buffer.asUint8List(0, data.lengthInBytes),
      flush: true,
    );
    await _chmod(file.path);
    return file;
  }

  static Future<void> _chmod(String path) async {
    if (!Platform.isAndroid && !Platform.isLinux) return;
    try {
      await Process.run('chmod', ['755', path]);
    } catch (_) {
      // 某些环境无 chmod，忽略
    }
  }
}
