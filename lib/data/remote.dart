import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:ssh2/ssh2.dart';

import '../core/settings.dart';
import 'pipeline.dart';

/// 远程执行：把 Linux 版 pipeline 推到服务器跑三阶段，拉回结果。
/// 语义对齐桌面端 remote.go。
class RemoteRunner {
  RemoteRunner._();

  static Future<List<Map<String, String>>> run({
    required AppSettings settings,
    required String censysJson,
    required void Function(String line) onLine,
  }) async {
    final host = settings.remoteHost.trim();
    if (host.isEmpty) throw Exception('服务器地址为空');
    final user = settings.remoteUser.trim().isEmpty ? 'root' : settings.remoteUser.trim();
    final port = settings.remotePort <= 0 ? 22 : settings.remotePort;

    final asset = await _loadPipeline();
    if (asset.length < 512 * 1024) {
      throw Exception('内嵌的 Linux 版 pipeline 缺失');
    }

    onLine('连接 $host:$port …');
    final socket = await SSHSocket.connect(host, port,
        timeout: const Duration(seconds: 15));

    final client = SSHClient(
      socket,
      username: user,
      onPasswordRequest: settings.remotePassword.isNotEmpty
          ? () => settings.remotePassword
          : null,
      identities: settings.remoteKeyPath.isNotEmpty
          ? [_readIdentity(settings.remoteKeyPath)]
          : null,
    );

    final workDir = '/tmp/cytest-${DateTime.now().millisecondsSinceEpoch}';

    try {
      onLine('创建远端目录 …');
      await _run(client, 'mkdir -p $workDir/bin $workDir/input $workDir/conf $workDir/output', onLine);

      onLine('上传 pipeline（${(asset.length / 1048576).toStringAsFixed(1)} MB）…');
      final sftp = await client.sftp();
      await _upload(sftp, '$workDir/bin/pipeline', asset);
      await _upload(sftp, '$workDir/input/data.txt', utf8.encode(censysJson));
      await _upload(sftp, '$workDir/conf/config.json', utf8.encode(_configJson(settings)));
      await sftp.close();

      onLine('开始三阶段测试 …');
      await _run(
        client,
        'cd $workDir && chmod +x bin/pipeline && '
        './bin/pipeline -data input/data.txt -config conf/config.json -result output/result.csv',
        onLine,
      );

      onLine('拉取结果 …');
      final out = await _runCapture(client, 'cat $workDir/output/result.csv');
      await _run(client, 'rm -rf $workDir', null);

      final rows = parseCsv(out);
      if (rows.isEmpty) throw Exception('远端结果为空');
      return rows;
    } finally {
      try {
        client.close();
      } catch (_) {}
    }
  }

  static Future<Uint8List> _loadPipeline() async {
    // 远程执行需要 Linux 版，随 APK 一起打包在 assets
    final data = await rootBundle.load('assets/pipeline-linux');
    return data.buffer.asUint8List(0, data.lengthInBytes);
  }

  static String _readIdentity(String path) {
    final file = File(path);
    if (!file.existsSync()) throw Exception('私钥不存在：$path');
    return file.readAsStringSync();
  }

  static String _configJson(AppSettings s) => const JsonEncoder.withIndent('  ').convert({
        'TargetSHA1Hash': s.fingerprint,
        'MaxSha1Concurrency': s.sha1Concurrency,
        'speedTestURL': s.speedUrl,
        'dialTimeout': s.dialTimeout,
        'downloadTimeout': s.downloadTimeout,
        'maxLatencyConcurrency': s.latencyConcurrency,
        'maxSpeedConcurrency': s.speedConcurrency,
        'maxLatency': s.maxLatency,
      });

  static Future<void> _upload(SFTPClient sftp, String remotePath, List<int> bytes) async {
    final file = await sftp.open(
      remotePath,
      mode: SftpFileOpenMode.create | SftpFileOpenMode.write | SftpFileOpenMode.truncate,
    );
    await file.write(Stream.value(Uint8List.fromList(bytes)));
    await file.close();
  }

  static Future<void> _run(
      SSHClient client, String cmd, void Function(String)? onLine) async {
    final session = await client.execute(cmd);
    await for (final chunk in session.stdout) {
      onLine?.call(utf8.decode(chunk, allowMalformed: true).trimRight());
    }
    await for (final chunk in session.stderr) {
      onLine?.call(utf8.decode(chunk, allowMalformed: true).trimRight());
    }
    await session.done;
  }

  static Future<String> _runCapture(SSHClient client, String cmd) async {
    final session = await client.execute(cmd);
    final buf = StringBuffer();
    await for (final chunk in session.stdout) {
      buf.write(utf8.decode(chunk, allowMalformed: true));
    }
    await session.done;
    return buf.toString();
  }
}
