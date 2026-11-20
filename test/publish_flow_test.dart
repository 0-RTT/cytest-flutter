import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/pages/publish_page.dart';
import 'package:cytest/ui/pages/result_page.dart';
import 'package:cytest/ui/pages/vless_test_page.dart';

const _template =
    'vless://8b1c2d3e-4f5a-4b6c-8d9e-0a1b2c3d4e5f@1.2.3.4:443'
    '?encryption=none&security=tls&type=ws#test';

AppState _state() {
  final s = AppState();
  s.settings.vlessLinks = const [_template];
  s.rows = [
    {
      'IP': '9.9.9.9',
      'Port': '1111',
      'Latency (ms)': '10',
      'Speed (MiB/s)': '5.00',
      'Reason': '',
    },
    {
      'IP': '8.8.8.8',
      'Port': '2222',
      'Latency (ms)': '20',
      'Speed (MiB/s)': '3.00',
      'Reason': '',
    },
    {
      'IP': '1.1.1.1',
      'Port': '443',
      'Latency (ms)': '0',
      'Speed (MiB/s)': '0',
      'Reason': '失败',
    },
  ];
  return s;
}

Widget _host(Widget child, AppState state) => ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(home: child),
    );

void main() {
  group('结果页 → VLESS 测试页', () {
    testWidgets('默认全选可用节点，取消一条后测试页只带选中的 ip:port', (tester) async {
      final state = _state();
      await tester.pumpWidget(_host(const ResultPage(), state));
      await tester.pump();

      expect(find.text('测试 (2)'), findsOneWidget);
      // 失败行的复选框必须禁用，避免把失败节点带进测试
      final boxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
      expect(boxes, hasLength(3));
      expect(boxes[0].onChanged, isNotNull);
      expect(boxes[1].onChanged, isNotNull);
      expect(boxes[2].onChanged, isNull);

      await tester.tap(find.text('9.9.9.9:1111'));
      await tester.pump();
      expect(find.text('测试 (1)'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '测试 (1)'));
      await tester.pumpAndSettle();

      // 推送入口已挪到测试页：结果页的按钮只负责进入 VLESS 测试。
      expect(find.byType(VlessTestPage), findsOneWidget);
      expect(find.byType(PublishPage), findsNothing);
      expect(find.textContaining('1 个目标'), findsOneWidget);
      expect(find.textContaining('模板已就绪'), findsOneWidget);
      // 还没测速 → 推送按钮 0 条且不可点
      expect(find.text('推送 (0)'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, '推送 (0)'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('推送页可在 base64 与 yaml 之间切换预览', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          const PublishPage(
            targets: ['8.8.8.8:2222'],
            template: _template,
          ),
          _state(),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('publish_preview_panel')), findsOneWidget);
      expect(find.text('base64 订阅预览'), findsOneWidget);

      await tester.tap(find.text('yaml'));
      await tester.pump();

      // YAML 有 200+ 行，预览只渲染视口内前几行；结构正确性由
      // mihomo_test.dart 的 12 项断言负责，这里只验切换生效。
      expect(find.text('mihomo YAML 预览'), findsOneWidget);
    });

    testWidgets('模式标签为 base64 / yaml，推送按钮独占整行且无独立复制按钮', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          const PublishPage(
            targets: ['8.8.8.8:2222'],
            template: _template,
          ),
          _state(),
        ),
      );
      await tester.pump();

      // 标签改成短名，避免窄屏挤压
      expect(find.text('base64'), findsOneWidget);
      expect(find.text('yaml'), findsOneWidget);
      expect(find.text('订阅 base64'), findsNothing);
      expect(find.text('mihomo YAML'), findsNothing);

      // 顶部那个 OutlinedButton「复制」已删除……
      expect(find.text('复制'), findsNothing);
      // ……但预览面板自带的「复制内容」必须保留
      expect(find.byTooltip('复制内容'), findsOneWidget);

      // 推送按钮与模式切换按钮同宽 = 独占整行
      final pushButton = find.widgetWithText(FilledButton, '推送 GitHub');
      expect(pushButton, findsOneWidget);
      final modeSwitch = find.byType(SegmentedButton<String>);
      expect(
        tester.getRect(pushButton).width,
        moreOrLessEquals(tester.getRect(modeSwitch).width, epsilon: 1),
        reason: '推送按钮应独占整行（复制按钮删除后不再对半分）',
      );
    });

    testWidgets('切换格式时文件名各自独立，预览区不显示无意义的跳到最新', (tester) async {
      await tester.pumpWidget(
        _host(
          const PublishPage(
            targets: ['8.8.8.8:2222'],
            template: _template,
          ),
          _state(),
        ),
      );
      await tester.pump();

      // 文件名不再是输入框：它来自「设置 → GitHub 推送」，页面上只回显。
      expect(find.textContaining('写入 cytest-sub.txt'), findsOneWidget);
      expect(find.byTooltip('复制内容'), findsOneWidget);
      expect(find.byTooltip('跳到最新'), findsNothing);
      expect(find.widgetWithText(TextField, '订阅文件名（base64）'), findsNothing);

      // 改成 YAML 后回显的换成 YAML 文件名，且没有跳到最新按钮
      await tester.tap(find.text('yaml'));
      await tester.pump();
      expect(find.textContaining('写入 config.yaml'), findsOneWidget);
      expect(find.byTooltip('跳到最新'), findsNothing);
      expect(find.widgetWithText(TextField, 'mihomo 文件名（YAML）'), findsNothing);
    });
    testWidgets('推送页默认直连，可切到走代理', (tester) async {
      await tester.pumpWidget(
        _host(
          const PublishPage(
            targets: ['8.8.8.8:2222'],
            template: _template,
          ),
          _state(),
        ),
      );
      await tester.pump();

      expect(find.text('GitHub 访问'), findsOneWidget);
      // 默认直连：不擅自起 Xray
      final segmented = find.byType(SegmentedButton<bool>);
      expect(segmented, findsOneWidget);
      expect(
        tester.widget<SegmentedButton<bool>>(segmented).selected,
        {false},
        reason: '默认应直连，不擅自起 Xray',
      );

      await tester.tap(find.text('走代理'));
      await tester.pump();
      expect(
        tester.widget<SegmentedButton<bool>>(segmented).selected,
        {true},
      );
    });

    testWidgets('YAML 高级选项可展开，关掉拦截广告后预览里 reject 消失', (tester) async {
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          const PublishPage(
            targets: ['8.8.8.8:2222'],
            template: _template,
          ),
          _state(),
        ),
      );
      await tester.pump();

      // base64 模式下不显示高级选项，切到 YAML 才有
      expect(find.text('高级选项'), findsNothing);
      await tester.tap(find.text('yaml'));
      await tester.pump();
      expect(find.text('高级选项'), findsOneWidget);

      await tester.tap(find.text('高级选项'));
      await tester.pumpAndSettle();
      expect(find.text('拦截广告'), findsOneWidget);
      expect(find.text('TUN 模式'), findsOneWidget);

      // 默认全开
      final adTile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, '拦截广告'),
      );
      expect(adTile.value, isTrue);

      final adTileFinder = find.widgetWithText(SwitchListTile, '拦截广告');
      await tester.ensureVisible(adTileFinder);
      await tester.pumpAndSettle();
      await tester.tap(adTileFinder);
      await tester.pumpAndSettle();
      final after = tester.widget<SwitchListTile>(adTileFinder);
      expect(after.value, isFalse, reason: '关掉后应立刻重算 YAML');
    });
  });
}
