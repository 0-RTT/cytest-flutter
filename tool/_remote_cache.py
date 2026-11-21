# -*- coding: utf-8 -*-
"""远程执行：引擎按哈希缓存到远端，失败也清理目录。"""
import io

p = 'lib/data/remote.dart'
s = io.open(p, encoding='utf-8').read()

if "package:crypto/crypto.dart" not in s:
    s = s.replace("import 'package:dartssh2/dartssh2.dart';",
                  "import 'package:crypto/crypto.dart';\nimport 'package:dartssh2/dartssh2.dart';", 1)

old = """    final workDir = '/tmp/cytest-${DateTime.now().millisecondsSinceEpoch}';

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
      } on Object {}
    }
  }"""

new = """    final workDir = '/tmp/cytest-${DateTime.now().millisecondsSinceEpoch}';

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

      final hasBin = (await _runCapture(
        client,
        'test -x "$remoteBin" && echo yes || echo no',
      ))
          .trim();
      if (hasBin == 'yes') {
        onLine('远端已有同版本引擎（${hash}），跳过上传');
      } else {
        onLine('上传 pipeline（${(asset.length / 1048576).toStringAsFixed(1)} MB）…');
        await _run(client, 'mkdir -p "$cacheDir"', null);
        final sftp = await client.sftp();
        // 先传 .part 再 mv：中途断线不会留下一个「看起来可用」的半截二进制。
        await _upload(sftp, '$remoteBin.part', asset);
        await sftp.close();
        await _run(client, 'chmod 755 "$remoteBin.part" && mv -f "$remoteBin.part" "$remoteBin"', null);
      }

      // 数据与配置每次都不同，必须每次传（只在引擎命中缓存时省上传）。
      final sftp2 = await client.sftp();
      await _upload(sftp2, '$workDir/input/data.txt', utf8.encode(censysJson));
      await _upload(sftp2, '$workDir/conf/config.json', utf8.encode(_configJson(settings)));
      await sftp2.close();

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
      // 清理必须放在 finally：原来写在成功路径末尾，SSH 断了 / 引擎报错就留下
      // 一堆 /tmp/cytest-*（每次几十 MB），跑几十轮就堆满 /tmp。
      try {
        await _run(client, 'rm -rf $workDir', null);
      } on Object {
        // 清理失败不影响结果交付，也不该盖住原始异常。
      }
      try {
        client.close();
      } on Object {}
    }
  }"""
assert old in s
s = s.replace(old, new, 1)
io.open(p, 'w', encoding='utf-8').write(s)
print('ok')
