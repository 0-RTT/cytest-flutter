import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';

import '../core/bin.dart';
import '../core/settings.dart';
import 'pipeline.dart';
import 'socks_socket.dart';

/// 远程执行：把 Linux 版 pipeline 推到服务器跑三阶段，拉回结果。
/// 语义对齐桌面端 remote.go。
class RemoteRunner {
  RemoteRunner._();

  static Future<List<Map<String, String>>> run({
    required AppSettings settings,
    required String censysJson,
    required void Function(String line) onLine,
    /// 非空 = 经本机 SOCKS5（Xray mixed 入站）连服务器；null = 直连。
    int? proxyPort,
  }) async {
    final host = settings.remoteHost.trim();
    if (host.isEmpty) throw Exception('服务器地址为空');
    final user = settings.remoteUser.trim().isEmpty ? 'root' : settings.remoteUser.trim();
    final port = settings.remotePort <= 0 ? 22 : settings.remotePort;

    final asset = await _loadPipeline();
    if (asset.length < 512 * 1024) {
      throw Exception('内嵌的 Linux 版 pipeline 缺失');
    }

    onLine('连接 $host:$port …${proxyPort == null ? '（直连）' : '（经本机代理 127.0.0.1:$proxyPort）'}');
    final socket = proxyPort == null
        ? await SSHSocket.connect(host, port,
            timeout: const Duration(seconds: 15))
        : await connectViaSocks5(
            proxyHost: '127.0.0.1',
            proxyPort: proxyPort,
            host: host,
            port: port,
          );

    final client = SSHClient(
      socket,
      username: user,
      onPasswordRequest: settings.remotePassword.isNotEmpty
          ? () => settings.remotePassword
          : null,
      identities: settings.remoteKeyPath.isNotEmpty
          ? SSHKeyPair.fromPem(_readIdentity(settings.remoteKeyPath))
          : null,
    );

    final workDir = '/tmp/cytest-${DateTime.now().millisecondsSinceEpoch}';

    // 引擎缓存：远端按内容哈希留一份，哈希没变就不再上传 6.8MB。
    // 用哈希而不是版本号：改一行 Go 代码哈希就变，缓存自然失效，不会用到旧二进制。
    final hash = sha1.convert(asset).toString().substring(0, 12);
    final home = (await _runCapture(client, r'echo $HOME')).trim();
    if (home.isEmpty) throw Exception('无法确定远端 HOME 目录');
    final cacheDir = '$home/.cytest';
    final remoteBin = '$cacheDir/pipeline-$hash';

    try {
      onLine('创建远端目录 …');
      await _run(client, 'mkdir -p $workDir/input $workDir/conf $workDir/output', onLine);

      final hasBin =
          (await _runCapture(client, 'test -x "$remoteBin" && echo yes || echo no')).trim();
      if (hasBin == 'yes') {
        onLine('远端已有同版本引擎（$hash），跳过上传');
      } else {
        onLine('上传 pipeline（${(asset.length / 1048576).toStringAsFixed(1)} MB）…');
        await _run(client, 'mkdir -p "$cacheDir"', null);
        final sftp = await client.sftp();
        // 先传 .part 再 mv：中途断线不会留下一个「看起来可用」的半截二进制。
        await _upload(sftp, '$remoteBin.part', asset);
        await sftp.close();
        await _run(client, 'chmod 755 "$remoteBin.part" && mv -f "$remoteBin.part" "$remoteBin"', null);
      }

      // 数据与配置每次不同，必须每次传。
      final sftpData = await client.sftp();
      await _upload(sftpData, '$workDir/input/data.txt', utf8.encode(censysJson));
      await _upload(sftpData, '$workDir/conf/config.json', utf8.encode(_configJson(settings)));
      await sftpData.close();

      onLine('开始三阶段测试 …');
      await _run(
        client,
        'cd $workDir && "$remoteBin" -data input/data.txt -config conf/config.json -result output/result.csv',
        onLine,
      );

      onLine('拉取结果 …');
      final out = await _runCapture(client, 'cat $workDir/output/result.csv');

      final rows = parseCsv(out);
      if (rows.isEmpty) throw Exception('远端结果为空');
      return rows;
    } finally {
      // 清理放在 finally：原来写在成功路径末尾，SSH 断了 / 引擎报错就会留下
      // 一堆 /tmp/cytest-*（每次几十 MB），跑几十轮就堆满 /tmp。
      // 缓存目录 ~/.cytest 不动，那是下次省上传的凭据。
      try {
        await _run(client, 'rm -rf $workDir', null);
      } catch (_) {
        // 清理失败不影响结果交付，也不该盖住原始异常。
      }
      try {
        client.close();
      } catch (_) {}
    }
  }

  static Future<Uint8List> _loadPipeline() async {
    // 远程执行需要 Linux 版，随 APK 打包在 assets
    return Uint8List.fromList(await Bins.loadLinuxPipeline());
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

  static Future<void> _upload(SftpClient sftp, String remotePath, List<int> bytes) async {
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
    // execute() 的返回类型非空（dartssh2 在连接失败时抛异常而不是返回 null），
    // 原先的 `if (session == null) return;` 是永远不会命中的死分支。
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
