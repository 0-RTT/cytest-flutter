import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/xray.dart';

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
}

List<int> _utf8(String s) => const Utf8Codec().encode(s);
