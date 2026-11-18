import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:cytest/data/link_test.dart';
import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/pages/publish_page.dart';
import 'package:cytest/ui/pages/vless_test_page.dart';

const _template =
    'vless://8b1c2d3e-4f5a-4b6c-8d9e-0a1b2c3d4e5f@1.2.3.4:443'
    '?encryption=none&security=tls&type=ws#test';

LinkTestResult _done(String host, int port, {int latency = 20, double speed = 1}) =>
    LinkTestResult(
      link: 'vless://x@$host:$port',
      name: '节点 $host',
      host: host,
      port: port,
      latencyMs: latency,
      speedMib: speed,
      state: ProbeState.done,
    );

LinkTestResult _failed(String host, int port) => LinkTestResult(
      link: 'vless://x@$host:$port',
      name: '坏节点 $host',
      host: host,
      port: port,
      error: '握手超时',
      state: ProbeState.failed,
    );

AppState _state(List<LinkTestResult> results) {
  final s = AppState();
  s.settings.vlessLinks = const [_template];
  s.linkResults = results;
  return s;
}

Widget _host(Widget child, AppState state) =>
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(home: child),
    );

void main() {
  group('VlessTestPage', () {
    testWidgets('默认全选测速成功项，失败项不可勾选', (tester) async {
      // 列表是懒加载的：给足高度让三行都真正构建出来。
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final state = _state([
        _done('9.9.9.9', 1111, speed: 5),
        _done('8.8.8.8', 2222, speed: 3),
        _failed('7.7.7.7', 3333),
      ]);
      await tester.pumpWidget(_host(
        VlessTestPage(targets: const ['9.9.9.9:1111'], template: _template),
        state,
      ));
      await tester.pump();

      expect(find.text('推送 (2)'), findsOneWidget);
      final boxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
      expect(boxes, hasLength(3));
      // 默认排序按延迟：9.9.9.9 与 8.8.8.8 都是 20ms，保持原顺序；失败项排最后。
      expect(boxes[0].value, isTrue);
      expect(boxes[1].value, isTrue);
      expect(boxes[2].value, isFalse);
      expect(boxes[2].onChanged, isNull);
    });

    testWidgets('取消一条后推送条数减少，点推送进入 PublishPage', (tester) async {
      final state = _state([
        _done('9.9.9.9', 1111, speed: 5),
        _done('8.8.8.8', 2222, speed: 3),
      ]);
      await tester.pumpWidget(_host(
        VlessTestPage(targets: const ['9.9.9.9:1111'], template: _template),
        state,
      ));
      await tester.pump();

      await tester.tap(find.text('9.9.9.9:1111'));
      await tester.pump();
      expect(find.text('推送 (1)'), findsOneWidget);

      await tester.tap(find.text('推送 (1)'));
      await tester.pumpAndSettle();
      expect(find.byType(PublishPage), findsOneWidget);
    });

    testWidgets('目标或模板为空时给出提示且不允许开始测试', (tester) async {
      final state = _state(const []);
      await tester.pumpWidget(_host(
        const VlessTestPage(targets: [], template: ''),
        state,
      ));
      await tester.pump();

      expect(find.textContaining('目标列表为空'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始测试'))
            .onPressed,
        isNull,
      );
      expect(find.text('推送 (0)'), findsOneWidget);
    });

    // 只有「模板为空」时提示语必须换成模板那条，不能误报「目标为空」——
    // 用户明明从结果页选了节点，被告知「返回结果页重新勾选」会直接懵。
    testWidgets('仅模板为空（目标非空）时提示的是模板缺失，且推送不可用', (tester) async {
      // 给一组「已测速成功」的结果：即使有可勾选项，_invalid 也必须压住推送。
      final state = _state([_done('9.9.9.9', 1111, speed: 5)]);
      await tester.pumpWidget(_host(
        const VlessTestPage(targets: ['9.9.9.9:1111'], template: ''),
        state,
      ));
      await tester.pump();

      expect(find.textContaining('没有可用的 vless 模板'), findsOneWidget);
      expect(find.textContaining('目标列表为空'), findsNothing);
      expect(find.text('未配置模板'), findsOneWidget);

      // linkResults 非空时开始按钮的文案是「重新测试」
      final start = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '重新测试'),
      );
      expect(start.onPressed, isNull, reason: '模板为空时不允许开测');

      // selectedCount 会是 1，但模板缺失 → 推送仍必须禁用
      final push = tester.widget<FilledButton>(
        find.byKey(const ValueKey('vless_test_push')),
      );
      expect(push.onPressed, isNull, reason: '模板为空时不允许推送');
    });

    testWidgets('取消全选后推送条数归零且按钮禁用', (tester) async {
      final state = _state([
        _done('9.9.9.9', 1111, speed: 5),
        _done('8.8.8.8', 2222, speed: 3),
      ]);
      await tester.pumpWidget(_host(
        VlessTestPage(targets: const ['9.9.9.9:1111'], template: _template),
        state,
      ));
      await tester.pump();

      // 默认按速度成功项全选 → 2
      expect(find.text('推送 (2)'), findsOneWidget);

      await tester.tap(find.text('取消全选'));
      await tester.pump();

      expect(find.text('推送 (0)'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('vless_test_push')))
            .onPressed,
        isNull,
      );

      // 再点「全选」回到 2
      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(find.text('推送 (2)'), findsOneWidget);
    });

    testWidgets('排序切换：按速度为默认顺序的反面时行序随之变化', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      // 延迟低的反而速度慢：两个维度给出不同顺序，才能证明切换真的生效
      final state = _state([
        _done('1.1.1.1', 1111, latency: 10, speed: 1.0),
        _done('2.2.2.2', 2222, latency: 200, speed: 9.0),
      ]);
      await tester.pumpWidget(_host(
        VlessTestPage(targets: const ['1.1.1.1:1111'], template: _template),
        state,
      ));
      await tester.pump();

      List<String> hostsInOrder() => tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => ((t.subtitle as Text).data ?? '').split(' · ').first)
          .toList();

      // 默认按延迟升序
      expect(hostsInOrder(), ['1.1.1.1:1111', '2.2.2.2:2222']);

      await tester.tap(find.text('按速度'));
      await tester.pump();

      // 按速度降序
      expect(hostsInOrder(), ['2.2.2.2:2222', '1.1.1.1:1111']);
    });
  });
}
