import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/pages/publish_page.dart';
import 'package:cytest/ui/pages/result_page.dart';

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
  group('结果页 → 推送页', () {
    testWidgets('默认全选可用节点，取消一条后推送页只带选中的 ip:port', (tester) async {
      final state = _state();
      await tester.pumpWidget(_host(const ResultPage(), state));
      await tester.pump();

      expect(find.text('推送 (2)'), findsOneWidget);
      // 失败行的复选框必须禁用，避免把失败节点推上去
      final boxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
      expect(boxes, hasLength(3));
      expect(boxes[0].onChanged, isNotNull);
      expect(boxes[1].onChanged, isNotNull);
      expect(boxes[2].onChanged, isNull);

      await tester.tap(find.text('9.9.9.9:1111'));
      await tester.pump();
      expect(find.text('推送 (1)'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '推送 (1)'));
      await tester.pumpAndSettle();

      expect(find.byType(PublishPage), findsOneWidget);
      expect(find.text('推送'), findsOneWidget);
      expect(find.textContaining('8.8.8.8:2222'), findsOneWidget);
      expect(find.textContaining('9.9.9.9:1111'), findsNothing);

      final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(fields.isNotEmpty, isTrue);
      expect(
        fields.any((f) => f.controller?.text.contains('vless://') ?? false),
        isTrue,
        reason: '模板链接应从设置页预填到输入框',
      );
    });

    testWidgets('推送页可在 base64 与 mihomo YAML 之间切换预览', (tester) async {
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
      expect(find.textContaining('@8.8.8.8:2222'), findsNothing);

      await tester.tap(find.text('mihomo YAML'));
      await tester.pump();

      expect(find.textContaining('server: 8.8.8.8'), findsOneWidget);
      expect(find.textContaining('port: 2222'), findsOneWidget);
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

      // 订阅格式：默认订阅文件名，预览复制按钮叫「复制内容」
      expect(find.text('订阅文件名（base64）'), findsOneWidget);
      expect(find.byTooltip('复制内容'), findsOneWidget);
      expect(find.byTooltip('跳到最新'), findsNothing);
      final subField = tester.widget<TextField>(
        find.widgetWithText(TextField, '订阅文件名（base64）'),
      );
      expect(subField.controller?.text, 'cytest-sub.txt');

      // 改成 YAML 后文件名切到 config.yaml，且没有跳到最新按钮
      await tester.tap(find.text('mihomo YAML'));
      await tester.pump();
      expect(find.text('mihomo 文件名（YAML）'), findsOneWidget);
      expect(find.byTooltip('跳到最新'), findsNothing);
      final yamlField = tester.widget<TextField>(
        find.widgetWithText(TextField, 'mihomo 文件名（YAML）'),
      );
      expect(yamlField.controller?.text, 'config.yaml');
    });
  });
}
