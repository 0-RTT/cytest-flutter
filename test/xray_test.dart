import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/link_probe.dart';
import 'package:cytest/data/vless.dart';
import 'package:cytest/data/xray.dart';

/// 造一个最小可用的 Vless（只填 buildBatchConfig 会读的字段）。
Vless _vless(String host, int port) => Vless(
      uuid: 'b831381d-6324-4d53-ad4f-8cda48b30811',
      host: host,
      port: port,
      network: 'ws',
      security: 'tls',
      sni: host,
      wsHost: host,
      wsPath: '/ws',
      alpn: '',
      fingerprint: '',
      mode: 'auto',
      name: host,
    );

/// 构造 [ProcessException] 的简写。
/// 真实签名是 `(executable, arguments, [message, errorCode])`。
ProcessException _ex(String message, int errorCode) => ProcessException(
      'xray',
      const <String>['version'],
      message,
      errorCode,
    );

/// 一个「能被 exec，且一定以非 0 退出」的可执行文件。
/// Windows 的 hostname.exe 不接受多余参数，以 1 退出；
/// POSIX 的 sh 把 version 当不存在的命令，以非 0 退出。
String _nonZeroExitExe() => Platform.isWindows ? 'hostname' : '/bin/sh';

/// 一个「能被 exec，且以 0 退出」的可执行文件。
String _zeroExitExe() => Platform.isWindows ? 'cmd' : '/bin/echo';

/// 把若干 chunk 喂给 [pumpLines]，等 future 完成（而不是靠 sleep）后返回所有行。
Future<List<String>> _collect(List<List<int>> chunks) async {
  final ctl = StreamController<List<int>>();
  final lines = <String>[];
  final pumping = pumpLines(ctl.stream, lines.add);
  for (final chunk in chunks) {
    ctl.add(chunk);
  }
  await ctl.close();
  await pumping;
  return lines;
}

void main() {
  group('describeProcessError 错误翻译（errno 优先）', () {
    test('errno 2 识别为文件不存在', () {
      final msg = describeProcessError(_ex('No such file or directory', 2));

      expect(msg, contains('文件不存在'));
      expect(msg, contains('No such file or directory'));
      expect(msg, contains('errno 2'));
    });

    test('errno 优先于文案：文案说 not found 但 errno 13 时按 Permission denied 判', () {
      final msg = describeProcessError(_ex('no such file', 13));

      expect(msg, contains('Permission denied'));
      expect(msg, contains('extractNativeLibs=true'));
      expect(msg, isNot(contains('文件不存在')));
    });

    test('errno 13 识别为 Permission denied', () {
      final msg = describeProcessError(_ex('Permission denied', 13));

      expect(msg, contains('Permission denied'));
      expect(msg, contains('extractNativeLibs=true'));
      expect(msg, contains('errno 13'));
    });

    test('errno 8 识别为 Exec format error，并指向 arm64-v8a / PIE', () {
      final msg = describeProcessError(_ex('Exec format error', 8));

      expect(msg, contains('Exec format error'));
      expect(msg, contains('jniLibs/arm64-v8a'));
      expect(msg, contains('ET_DYN'));
      expect(msg, contains('errno 8'));
    });

    test('errno 为 0 时回落到英文文案匹配（locale 无关兜底）', () {
      expect(
        describeProcessError(_ex('executable not found', 0)),
        contains('文件不存在'),
      );
      expect(
        describeProcessError(_ex('Permission denied', 0)),
        contains('Permission denied'),
      );
      expect(
        describeProcessError(_ex('Exec format error', 0)),
        contains('Exec format error'),
      );
    });

    test('errno 与文案都不认识时原样返回，不吞掉原文', () {
      final msg = describeProcessError(_ex('something weird happened', 42));

      expect(msg, contains('something weird happened'));
      expect(msg, contains('errno 42'));
      expect(msg, isNot(contains('文件不存在')));
      expect(msg, isNot(contains('Exec format error')));
    });

    test('errorCode 为 0 时不追加 errno 后缀', () {
      final msg = describeProcessError(_ex('boom', 0));

      expect(msg, 'boom');
      expect(msg, isNot(contains('errno')));
    });

    test('message 为空时退回 ProcessException 字样', () {
      expect(describeProcessError(_ex('', 0)), contains('ProcessException'));
    });
  });

  group('checkXrayBinary 起进程前自检', () {
    test('二进制不存在时抛出可读异常（不再继续启动进程）', () async {
      final missing = '${Directory.systemTemp.path}/cytest_missing_xray_bin';

      await expectLater(
        checkXrayBinary(missing),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains(missing),
          ),
        ),
      );
    });

    test('目标不是可执行文件时抛出异常并带上路径', () async {
      final dir = await Directory.systemTemp.createTemp('cytest_xray_test');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final notExe = File('${dir.path}/not_an_executable.txt');
      await notExe.writeAsString('just text, not a binary');

      await expectLater(
        checkXrayBinary(notExe.path),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains(notExe.path),
          ),
        ),
      );
    });

    test('子进程非 0 退出时抛出「自检失败」并带上 exitCode', () async {
      await expectLater(
        checkXrayBinary(_nonZeroExitExe()),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('自检失败'), contains('exitCode=')),
          ),
        ),
      );
    });

    test('能正常执行的二进制返回非空版本行', () async {
      final version = await checkXrayBinary(_zeroExitExe());

      expect(version, isNotEmpty);
    });

    test('onLine 回调能拿到子进程输出（自检输出进环形缓冲的前提）', () async {
      final seen = <String>[];

      await checkXrayBinary(_zeroExitExe(), onLine: seen.add);

      expect(seen, isNotEmpty);
    });
  });

  group('pumpLines 逐行切分', () {
    test('跨 chunk 断行：半行不提前发射，拼回完整后按序发射', () async {
      final lines = await _collect(<List<int>>[
        _utf8('hel'),
        _utf8('lo\nwor'),
        _utf8('ld\n'),
      ]);

      expect(lines, <String>['hello', 'world']);
    });

    test('结尾没有换行的半行在流结束时兜底发射', () async {
      final lines = await _collect(<List<int>>[_utf8('tail-no-newline')]);

      expect(lines, <String>['tail-no-newline']);
    });

    test('只有空白的尾行不发射', () async {
      final lines = await _collect(<List<int>>[_utf8('a\n   ')]);

      expect(lines, <String>['a']);
    });

    test('超长单行（>8192，全程无换行）不丢字节', () async {
      const total = 20000;
      final payload = 'x' * total;
      final chunks = <List<int>>[
        for (var i = 0; i < total; i += 1000)
          _utf8(payload.substring(i, i + 1000)),
      ];

      final lines = await _collect(chunks);

      expect(lines.fold<int>(0, (sum, l) => sum + l.length), total);
      expect(lines.length, greaterThan(1), reason: '应被强制切成多段');
      expect(
        lines.every((l) => l.length <= 8192 + 1000),
        isTrue,
        reason: '单段上界 = 8192 + 单个 chunk 长度，缓存不会无限膨胀',
      );
    });

    test('单个 chunk 内的多行全部按序拿到', () async {
      final payload = List<String>.generate(100, (i) => 'l$i').join('\n');
      final lines = await _collect(<List<int>>[_utf8('$payload\n')]);

      expect(lines.length, 100);
      expect(lines.first, 'l0');
      expect(lines.last, 'l99');
    });

    test('空行原样发射（去留由环形缓冲决定，切分层不做业务过滤）', () async {
      final lines = await _collect(<List<int>>[_utf8('a\n\nb\n')]);

      expect(lines, <String>['a', '', 'b']);
    });

    test('CRLF 的 \\r 原样留在行尾（由上层 trimRight 处理）', () async {
      final lines = await _collect(<List<int>>[_utf8('a\r\nb\r\n')]);

      expect(lines, <String>['a\r', 'b\r']);
      expect(lines.map((l) => l.trimRight()).toList(), <String>['a', 'b']);
    });

    test('多字节字符被 chunk 边界切断时行数不变（不丢行）', () async {
      // 注意：当前实现是逐 chunk 独立解码，被切断的字符会出现 U+FFFD 替换符。
      // 这里只钉「不丢行 / 行数不变」这条稳定契约，避免把替换符写进断言而锁死实现。
      final bytes = _utf8('中文\n下一行\n');

      final lines = await _collect(<List<int>>[
        bytes.sublist(0, 2), // 故意切断第一个汉字（3 字节）
        bytes.sublist(2),
      ]);

      expect(lines.length, 2);
      expect(lines[1], '下一行');
    });

    test('流上带错误时不会抛给调用方，且 future 仍能完成', () async {
      final ctl = StreamController<List<int>>();
      final lines = <String>[];
      final pumping = pumpLines(ctl.stream, lines.add);

      ctl.add(_utf8('ok\n'));
      ctl.addError(const SocketException('stdout 上的伪错误'));
      await ctl.close();

      await expectLater(pumping, completes);
      expect(lines, <String>['ok']);
    });
  });

  group('buildBatchConfig 批量配置（单进程 N 入站）', () {
    test('两个节点 → 两个 mixed 入站 + 两条 routing 规则 + direct/block 兜底', () {
      final nodes = <(Vless, int)>[
        (_vless('a.example', 443), 20000),
        (_vless('b.example', 8443), 20001),
      ];

      final map = jsonDecode(buildBatchConfig(nodes)) as Map<String, dynamic>;
      final inbounds = (map['inbounds'] as List).cast<Map<String, dynamic>>();
      final outbounds = (map['outbounds'] as List).cast<Map<String, dynamic>>();
      final rules = ((map['routing'] as Map)['rules'] as List)
          .cast<Map<String, dynamic>>();

      expect(inbounds.length, 2);
      expect(inbounds[0]['protocol'], 'mixed');
      expect(inbounds[0]['listen'], '127.0.0.1');
      expect(inbounds[0]['port'], 20000);
      expect(inbounds[1]['port'], 20001);

      expect(outbounds.length, 4, reason: '2 个节点出站 + direct + block');
      expect(outbounds[2]['tag'], 'direct');
      expect(outbounds[3]['tag'], 'block');

      expect(rules.length, 2);
      expect(rules[0]['inboundTag'], <String>['in-0']);
      expect(rules[0]['outboundTag'], 'out-0');
      expect(rules[1]['inboundTag'], <String>['in-1']);
      expect(rules[1]['outboundTag'], 'out-1');

      expect((map['log'] as Map)['loglevel'], 'warning');
    });

    test('入站口与节点一一对应：out-N 指向第 N 个节点的 host/port', () {
      final nodes = <(Vless, int)>[
        (_vless('a.example', 443), 20000),
        (_vless('b.example', 8443), 20001),
      ];

      final map = jsonDecode(buildBatchConfig(nodes)) as Map<String, dynamic>;
      final outbounds = (map['outbounds'] as List).cast<Map<String, dynamic>>();

      final first =
          (((outbounds[0]['settings'] as Map)['vnext'] as List).first as Map);
      final second =
          (((outbounds[1]['settings'] as Map)['vnext'] as List).first as Map);

      expect(outbounds[0]['tag'], 'out-0');
      expect(first['address'], 'a.example');
      expect(first['port'], 443);
      expect(outbounds[1]['tag'], 'out-1');
      expect(second['address'], 'b.example');
      expect(second['port'], 8443);
    });
  });

  group('waitPorts 端口就绪门禁（K5：全部就绪才算成功）', () {
    test('真实监听中的端口 → true', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      final port = server.port;

      final ok = await XrayProc().waitPorts(
        <int>[port],
        timeout: const Duration(seconds: 2),
      );

      expect(ok, isTrue);
    });

    test('没有监听的端口 → false（超时返回，不抛异常）', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close(); // 关掉后这个口没人监听

      final watch = Stopwatch()..start();
      final ok = await XrayProc().waitPorts(
        <int>[port],
        timeout: const Duration(milliseconds: 400),
      );

      expect(ok, isFalse);
      expect(watch.elapsedMilliseconds, lessThan(5000));
    });

    test('有一个端口没就绪就整体 false（不允许「部分就绪」进探测）', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close();

      final ok = await XrayProc().waitPorts(
        <int>[server.port, deadPort],
        timeout: const Duration(milliseconds: 400),
      );

      expect(ok, isFalse);
    });

    test('空列表视为就绪（没有端口要等）', () async {
      expect(await XrayProc().waitPorts(const <int>[]), isTrue);
    });
  });

  group('K4 批量模式语义（running 只代表单线路代理）', () {
    test('mode == batch 时 running 为 false（批量进程不是可用代理）', () {
      final proc = XrayProc()..debugSetModeForTest(XrayMode.batch);

      expect(proc.mode, XrayMode.batch);
      expect(proc.running, isFalse);
    });

    test('mode == line 时 running 为 true，none 时为 false', () {
      final proc = XrayProc();
      expect(proc.running, isFalse);

      proc.debugSetModeForTest(XrayMode.line);
      expect(proc.running, isTrue);

      proc.debugSetModeForTest(XrayMode.none);
      expect(proc.running, isFalse);
    });

    test('批量运行中调用 start() 抛 XrayBusyException，文案可直接展示', () async {
      final proc = XrayProc()..debugSetModeForTest(XrayMode.batch);

      await expectLater(
        proc.start(_vless('a.example', 443)),
        throwsA(
          isA<XrayBusyException>()
              .having((e) => e.message, 'message', kBatchRunningMessage)
              .having((e) => e.toString(), 'toString', kBatchRunningMessage),
        ),
      );
    });

    test('K4 提示文案常量（T04 直接引用，改动会同时让此处失败）', () {
      expect(kBatchRunningMessage, '测速进行中，请先停止测速');
      expect(kProxyStoppedByTestMessage, '测速已停止代理线路');
    });

    test('startBatch 传空列表直接返回可读错误，不起进程', () async {
      final error = await XrayProc().startBatch(const <(Vless, int)>[]);

      expect(error, '没有可测的节点');
    });
  });

  group('terminateProcess（T02 验收 2：stop 返回后进程确已退出）', () {
    test('长跑进程被终止：返回时 exitCode 已 resolve，且不无限等', () async {
      final proc = await _spawnLongRunning();
      addTearDown(() => proc.kill(ProcessSignal.sigkill));

      final watch = Stopwatch()..start();
      await terminateProcess(proc, grace: const Duration(milliseconds: 800));
      watch.stop();

      // 返回后必须已经能拿到退出码（不是「还在退出中」）
      final code = await proc.exitCode.timeout(const Duration(seconds: 2));
      expect(code, isNotNull);
      expect(
        watch.elapsedMilliseconds,
        lessThan(4000),
        reason: '最多两个宽限期（2×800ms）+ 调度余量',
      );
    });

    test('幂等：进程已退出后再调用不抛异常', () async {
      final proc = await _spawnLongRunning();
      await terminateProcess(proc, grace: const Duration(milliseconds: 500));

      await expectLater(
        terminateProcess(proc, grace: const Duration(milliseconds: 500)),
        completes,
      );
    });

    test('批量端口超时只有一份口径：直接引用 link_probe 的 kPortReadyTimeout', () {
      expect(kPortReadyTimeout, const Duration(seconds: 12));
      // xray.dart 不得再定义同名/同值的第二个常量（T03 会两处各改一处而漏另一处）
      expect(kPortReadyTimeout.inSeconds, 12);
    });
  });
}

/// 起一个「会跑很久」的进程，用来验证 terminateProcess 真的能把它收掉。
///
/// Windows 的 `ping -n 30` 约 29s；POSIX 的 `sleep 30` 同理。
/// 必须把 stdout/stderr 读走：否则子进程写满管道缓冲区会阻塞，
/// 「终止」测试就变成了「测管道」。
Future<Process> _spawnLongRunning() async {
  final proc = Platform.isWindows
      ? await Process.start('ping', const <String>['-n', '30', '127.0.0.1'])
      : await Process.start('sleep', const <String>['30']);
  unawaited(proc.stdout.drain<void>());
  unawaited(proc.stderr.drain<void>());
  return proc;
}

List<int> _utf8(String s) => const Utf8Codec().encode(s);
