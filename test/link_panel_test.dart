import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cytest/data/link_test.dart';
import 'package:cytest/ui/widgets/link_test_panel.dart';

/// 造一条结果（默认是「测出速度」的可用条目）。
LinkTestResult _result({
  String host = '1.1.1.1',
  int port = 443,
  int latencyMs = 100,
  double? speedMib,
  String? error,
  ProbeState state = ProbeState.done,
  String? name,
}) =>
    LinkTestResult(
      link: 'vless://$host:$port',
      name: name ?? '$host:$port',
      host: host,
      port: port,
      latencyMs: latencyMs,
      speedMib: speedMib,
      error: error,
      state: state,
    );

Widget _host(LinkTestPanel panel) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: panel)),
    );

LinkTestPanel _panel(
  List<LinkTestResult> results, {
  String stage = '完成',
  bool running = false,
  VoidCallback? onCancel,
}) =>
    LinkTestPanel(
      results: results,
      stage: stage,
      running: running,
      onCancel: onCancel ?? () {},
    );

void main() {
  group('LinkTestPanel · D2 命门：未测绝不显示 0', () {
    testWidgets('speedMib 为 null 时显示「未测」，且不得出现 0.00 MiB/s', (tester) async {
      final unmeasured = _result(latencyMs: 88);

      await tester.pumpWidget(_host(_panel(<LinkTestResult>[unmeasured])));

      expect(find.text('未测'), findsOneWidget);
      expect(find.textContaining('0.00 MiB/s'), findsNothing);
      expect(find.text('88 ms'), findsOneWidget);
    });

    testWidgets('测出速度时按两位小数显示 MiB/s（单位不是 MB/s）', (tester) async {
      await tester.pumpWidget(
        _host(_panel(<LinkTestResult>[_result(speedMib: 8.114)])),
      );

      expect(find.text('8.11 MiB/s'), findsOneWidget);
      expect(find.textContaining('MB/s'), findsNothing);
      expect(find.text('未测'), findsNothing);
    });

    testWidgets('ttfb 未知（-1）显示「—」，不显示 -1 ms', (tester) async {
      await tester.pumpWidget(
        _host(_panel(<LinkTestResult>[
          _result(latencyMs: -1, state: ProbeState.pending),
        ])),
      );

      expect(find.text('—'), findsOneWidget);
      expect(find.textContaining('-1 ms'), findsNothing);
    });

    testWidgets('取消态显示「已取消」，不算失败也不算可用', (tester) async {
      await tester.pumpWidget(
        _host(_panel(<LinkTestResult>[
          _result(state: ProbeState.cancelled, latencyMs: -1),
        ])),
      );

      expect(find.text('已取消'), findsOneWidget);
      expect(find.text('未测'), findsNothing);
    });
  });

  group('LinkTestPanel · 失败展示与筛选', () {
    testWidgets('失败行显示错误原文，且「只看失败」只留失败行', (tester) async {
      final ok = _result(host: '9.9.9.9', speedMib: 5.0);
      final bad = _result(
        host: '8.8.8.8',
        error: '连接失败：Connection refused',
        state: ProbeState.failed,
        latencyMs: -1,
      );

      await tester.pumpWidget(_host(_panel(<LinkTestResult>[ok, bad])));
      expect(find.text('9.9.9.9:443'), findsOneWidget);
      expect(find.text('8.8.8.8:443'), findsOneWidget);
      expect(find.text('连接失败：Connection refused'), findsOneWidget);

      await tester.tap(find.text('只看失败'));
      await tester.pumpAndSettle();

      expect(find.text('8.8.8.8:443'), findsOneWidget);
      expect(find.text('9.9.9.9:443'), findsNothing);
    });

    testWidgets('「只看失败」筛选后没有失败项时给出空态文案', (tester) async {
      await tester.pumpWidget(
        _host(_panel(<LinkTestResult>[_result(speedMib: 1.0)])),
      );

      await tester.tap(find.text('只看失败'));
      await tester.pumpAndSettle();

      expect(find.text('没有符合条件的条目'), findsOneWidget);
    });
  });

  group('LinkTestPanel · 排序与进度', () {
    testWidgets('按速度：降序，未测永远排最后', (tester) async {
      final slow = _result(host: '1.1.1.1', speedMib: 1.0, latencyMs: 10);
      final fast = _result(host: '2.2.2.2', speedMib: 9.0, latencyMs: 90);
      final none = _result(host: '3.3.3.3', latencyMs: 5);

      await tester.pumpWidget(
        _host(_panel(<LinkTestResult>[none, slow, fast])),
      );

      final titles = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .where((d) => d != null && d.endsWith(':443'))
          .toList();

      expect(titles.first, '2.2.2.2:443', reason: '最快的排第一');
      expect(titles.last, '3.3.3.3:443', reason: '未测永远排最后');
    });

    testWidgets('按延迟：升序，未知延迟排最后', (tester) async {
      final slow = _result(host: '1.1.1.1', latencyMs: 300, speedMib: 1.0);
      final fast = _result(host: '2.2.2.2', latencyMs: 50, speedMib: 1.0);
      final unknown = _result(
        host: '3.3.3.3',
        latencyMs: -1,
        state: ProbeState.failed,
        error: '超时',
      );

      await tester.pumpWidget(
        _host(_panel(<LinkTestResult>[slow, unknown, fast])),
      );
      await tester.tap(find.text('按延迟'));
      await tester.pumpAndSettle();

      final titles = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .where((d) => d != null && d.endsWith(':443'))
          .toList();

      expect(titles.first, '2.2.2.2:443');
      expect(titles.last, '3.3.3.3:443');
    });

    testWidgets('进度显示「已完成 / 总数」，运行中才有取消按钮', (tester) async {
      final done = _result(host: '1.1.1.1', speedMib: 2.0);
      final pending =
          _result(host: '2.2.2.2', state: ProbeState.pending, latencyMs: -1);

      await tester.pumpWidget(
        _host(_panel(
          <LinkTestResult>[done, pending],
          stage: '速度探测',
          running: true,
        )),
      );

      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('速度探测'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);

      await tester.pumpWidget(
        _host(_panel(<LinkTestResult>[done, pending], stage: '完成')),
      );
      expect(find.text('取消'), findsNothing);
    });

    testWidgets('空列表显示「还没有结果」', (tester) async {
      await tester.pumpWidget(_host(_panel(<LinkTestResult>[])));

      expect(find.text('还没有结果'), findsOneWidget);
    });
  });
}
