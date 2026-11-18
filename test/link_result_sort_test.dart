import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/link_result_sort.dart';
import 'package:cytest/data/link_test.dart';

LinkTestResult _r(
  String host,
  int port, {
  int latency = -1,
  double? speed,
  String? error,
  ProbeState state = ProbeState.done,
}) =>
    LinkTestResult(
      link: 'vless://x@$host:$port',
      name: '$host:$port',
      host: host,
      port: port,
      latencyMs: latency,
      speedMib: speed,
      error: error,
      state: state,
    );

void main() {
  group('sortLinkResults · 按速度', () {
    test('成功项按速度倒序，失败项与未测项排末尾', () {
      final fast = _r('1.1.1.1', 443, speed: 9.5);
      final slow = _r('2.2.2.2', 443, speed: 1.2);
      final failed = _r('3.3.3.3', 443, error: '超时', state: ProbeState.failed);
      final untested = _r('4.4.4.4', 443, latency: 30);

      final sorted = sortLinkResults(
        [failed, untested, slow, fast],
        sort: LinkResultSort.speed,
      );

      expect(sorted.map((r) => r.host).toList(),
          ['1.1.1.1', '2.2.2.2', '3.3.3.3', '4.4.4.4']);
    });
  });

  group('sortLinkResults · 按延迟', () {
    test('已知延迟升序，未知延迟排末尾', () {
      final slow = _r('1.1.1.1', 443, latency: 180);
      final fast = _r('2.2.2.2', 443, latency: 12);
      final unknown = _r('3.3.3.3', 443, error: '超时', state: ProbeState.failed);

      final sorted = sortLinkResults(
        [slow, unknown, fast],
        sort: LinkResultSort.latency,
      );

      expect(sorted.map((r) => r.host).toList(),
          ['2.2.2.2', '1.1.1.1', '3.3.3.3']);
    });

    test('同值保持原有相对顺序（稳定排序）', () {
      final a = _r('1.1.1.1', 443, latency: 20);
      final b = _r('2.2.2.2', 443, latency: 20);
      final c = _r('3.3.3.3', 443, latency: 5);

      final sorted = sortLinkResults([a, b, c], sort: LinkResultSort.latency);
      expect(sorted.map((r) => r.host).toList(), ['3.3.3.3', '1.1.1.1', '2.2.2.2']);
    });
  });

  group('sortLinkResults · 边界', () {
    test('空列表返回空列表（两种维度都不崩）', () {
      expect(sortLinkResults(const [], sort: LinkResultSort.latency), isEmpty);
      expect(sortLinkResults(const [], sort: LinkResultSort.speed), isEmpty);
    });

    test('单项列表原样返回', () {
      final only = _r('1.1.1.1', 443, latency: 30, speed: 2);
      expect(sortLinkResults([only], sort: LinkResultSort.latency), [only]);
      expect(sortLinkResults([only], sort: LinkResultSort.speed), [only]);
    });

    test('按速度：全部失败时保持原有相对顺序（稳定）', () {
      final a = _r('1.1.1.1', 443, error: '超时', state: ProbeState.failed);
      final b = _r('2.2.2.2', 443, error: '拒绝', state: ProbeState.failed);
      final sorted = sortLinkResults([a, b], sort: LinkResultSort.speed);
      expect(sorted.map((r) => r.host).toList(), ['1.1.1.1', '2.2.2.2']);
    });

    // hasSpeed 的口径是「ok && speedMib > 0」，所以 speed=0 与「未测」同档，
    // 都排在有速度项之后 —— 这里钉住该口径，避免有人改成 `speedMib != 0`。
    test('按速度：速度为 0 与未测项同档，排在有速度项之后', () {
      final zero = _r('1.1.1.1', 443, speed: 0);
      final some = _r('2.2.2.2', 443, speed: 4.2);
      final untested = _r('3.3.3.3', 443);
      final sorted =
          sortLinkResults([zero, untested, some], sort: LinkResultSort.speed);
      // 有速度的在前（倒序），速度 0 与未测项同为「无正速度」落到末尾
      expect(sorted.first.host, '2.2.2.2');
      expect(sorted.map((r) => r.host).toList().sublist(1),
          ['1.1.1.1', '3.3.3.3']);
    });
  });

  test('不修改入参列表', () {
    final a = _r('1.1.1.1', 443, speed: 1);
    final b = _r('2.2.2.2', 443, speed: 5);
    final input = [a, b];
    sortLinkResults(input, sort: LinkResultSort.speed);
    expect(input.first.host, '1.1.1.1');
  });
}
