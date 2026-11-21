import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:cytest/data/history.dart';
import 'package:cytest/data/link_test.dart';
import 'package:cytest/app.dart';
import 'package:cytest/ui/widgets/glass.dart';
import 'package:cytest/state/app_state.dart';
import 'package:cytest/ui/pages/history_page.dart';
import 'package:cytest/ui/pages/remote_page.dart';
import 'package:cytest/ui/home.dart';

/// 用 golden 把「记录页」渲染成 PNG，不需要模拟器/真机。
///
/// 中文能不能看清取决于字体：`flutter test` 默认是 Ahem（全是方块），
/// 所以这里显式加载系统字体。跑法：
/// `flutter test --update-goldens test/history_preview_test.dart`
Future<void> _loadCjkFont() async {
  // 图标也得单独加载：测试环境默认只有 Ahem，Material Icons 不加载会渲染成方块。
  final iconFont = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? r'D:\cytest-app\.workbuddy\tmp\env\flutter'}'
    '/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
  );
  if (iconFont.existsSync()) {
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future<ByteData>.value(
          ByteData.view(iconFont.readAsBytesSync().buffer)));
    await loader.load();
  }

  for (final path in <String>[
    r'C:\Windows\Fonts\msyh.ttc',
    r'C:\Windows\Fonts\simhei.ttf',
  ]) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = file.readAsBytesSync();
    final loader = FontLoader('PreviewCJK')
      ..addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
    await loader.load();
    return;
  }
  fail('找不到中文字体，预览图会全是方块');
}

// 直接复用线上主题：预览图必须和真机一致，否则调的是「假界面」。
// 只额外把字体族换成预览用的中文字体（测试环境没有系统中文回退）。
ThemeData _theme() {
  final base = CytestApp.buildTheme(Brightness.light);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'PreviewCJK'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'PreviewCJK'),
  );
}

LinkTestResult _result({
  required String name,
  required String host,
  required int port,
  int latency = -1,
  double? speed,
  String? error,
  ProbeState state = ProbeState.done,
}) =>
    LinkTestResult(
      link: 'vless://uuid@$host:$port?encryption=none#${Uri.encodeComponent(name)}',
      name: name,
      host: host,
      port: port,
      latencyMs: latency,
      speedMib: speed,
      error: error,
      state: state,
    );

LinkTestRun _run() => LinkTestRun(
      id: '1763612400000',
      createdAt: DateTime(2026, 11, 20, 15, 12).millisecondsSinceEpoch,
      mode: LinkTestMode.auto,
      results: [
        _result(name: '🇭🇰 香港 01', host: '203.0.113.11', port: 443, latency: 42, speed: 18.62),
        _result(name: '🇯🇵 东京 02', host: '203.0.113.12', port: 8443, latency: 96, speed: 6.10),
        _result(name: '🇸🇬 新加坡 03', host: '203.0.113.13', port: 443, latency: 121),
        _result(
          name: '🇺🇸 洛杉矶 04',
          host: '203.0.113.14',
          port: 443,
          state: ProbeState.failed,
          error: '连接失败：Connection refused',
        ),
      ],
    );

// 线上每个页面都活在 GlassBackground（#F2F2F7）里，预览也必须包一层，
// 否则白卡贴在白底上，看不出层次（会误判成「卡片没描边、挤在一起」）。
Widget _app(Widget child) => ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        builder: (context, page) =>
            GlassBackground(child: page ?? const SizedBox.shrink()),
        home: child,
      ),
    );

void main() {
  setUpAll(_loadCjkFont);

  testWidgets('记录页预览：三个分组 + VLESS 历史', (tester) async {
    tester.view.physicalSize = const Size(1080, 2160);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(HistoryPage(
      loadRuns: () async => const [
        RecordInfo(id: '2026-11-20_12-30-00', at: '2026-11-20 12:30', total: 64, usable: 23, fastest: 12.34),
        RecordInfo(id: '2026-11-19_22-05-11', at: '2026-11-19 22:05', total: 128, usable: 51, fastest: 8.90),
      ],
      loadArchives: () async => const [
        RecordInfo(id: 'AS13335-20261120-091000', at: '2026-11-20 09:10', total: 512, bytes: 184320, isArchive: true),
      ],
      // 远程结果也要注入：不注入会去读真实目录（测试环境没有 path_provider）。
      loadRemote: () async => const [
        RecordInfo(id: 'AS13335-20261120-233012-remote', at: '2026-11-20 23:30', total: 59, usable: 31, fastest: 9.87, isRemote: true),
      ],
      loadLinkRuns: () async => [_run()],
    )));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(HistoryPage),
      matchesGoldenFile('goldens/history_list.png'),
    );
  });

  testWidgets('记录页预览：多选删除态', (tester) async {
    tester.view.physicalSize = const Size(1080, 2160);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(HistoryPage(
      selectAllOnLoad: true,
      loadRuns: () async => const [
        RecordInfo(id: '2026-11-20_12-30-00', at: '2026-11-20 12:30', total: 64, usable: 23, fastest: 12.34),
        RecordInfo(id: '2026-11-19_22-05-11', at: '2026-11-19 22:05', total: 128, usable: 51, fastest: 8.90),
      ],
      loadArchives: () async => const [
        RecordInfo(id: 'AS13335-20261120-091000', at: '2026-11-20 09:10', total: 512, bytes: 184320, isArchive: true),
      ],
      loadRemote: () async => const [
        RecordInfo(id: 'AS13335-20261120-233012-remote', at: '2026-11-20 23:30', total: 59, usable: 31, fastest: 9.87, isRemote: true),
      ],
      loadLinkRuns: () async => [_run()],
    )));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(HistoryPage),
      matchesGoldenFile('goldens/history_selecting.png'),
    );
  });

  testWidgets('远程执行页预览：访问方式=走代理', (tester) async {
    tester.view.physicalSize = const Size(1080, 2160);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final state = AppState();
    state.settings.remoteHost = '203.0.113.9';
    state.settings.remoteUser = 'root';
    state.settings.remotePort = 22;
    state.settings.remoteUseProxy = true;

    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        builder: (context, page) =>
            GlassBackground(child: page ?? const SizedBox.shrink()),
        home: const RemotePage(),
      ),
    ));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(RemotePage),
      matchesGoldenFile('goldens/remote_proxy.png'),
    );
  });

  testWidgets('远程执行页预览：已载入数据', (tester) async {
    tester.view.physicalSize = const Size(1080, 2160);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final state = AppState();
    state.settings.remoteHost = '203.0.113.9';
    state.settings.remoteUser = 'root';
    state.settings.remotePort = 22;
    state.settings.remoteUseProxy = false;

    // 模拟从记录里选中的数据（页面只读展示，不再有粘贴框）。
    final fake = '{"results":{"hits":[]}}' * 40;

    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        builder: (context, page) =>
            GlassBackground(child: page ?? const SizedBox.shrink()),
        home: RemotePage(initialInput: fake),
      ),
    ));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(RemotePage),
      matchesGoldenFile('goldens/remote_data.png'),
    );
  });

  testWidgets('首页预览：Bento + 分组列表', (tester) async {
    tester.view.physicalSize = const Size(1080, 2160);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final state = AppState();
    // 造几条「可用」结果，让便当盒有数字可显示。
    state.rows = [
      for (var i = 0; i < 6; i++)
        {
          'IP': '104.16.0.$i',
          'Port': '443',
          'Latency (ms)': '${15 + i * 7}',
          'Speed (MiB/s)': '${18 + i * 3.5}',
          'Reason': '',
        },
    ];

    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        builder: (context, page) =>
            GlassBackground(child: page ?? const SizedBox.shrink()),
        home: const HomeShell(),
      ),
    ));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(HomeShell),
      matchesGoldenFile('goldens/home_ios.png'),
    );
  });
}
