import 'package:flutter/material.dart';

import 'ui/home.dart';

class CytestApp extends StatelessWidget {
  const CytestApp({super.key});

  /// 深青色主色：比原来的亮青更沉，配暖灰底更耐看（参考系统「更多 / 首页」那套配色）。
  static const _seed = Color(0xFF0E7C66);

  /// 暖灰底：参考图里页面底色不是纯白，而是带一点米黄的浅灰，
  /// 白卡片浮在上面才有层次。纯白卡片放在纯白底上会糊成一片。
  static const _lightBg = Color(0xFFF1F0EB);
  static const _darkBg = Color(0xFF14150F);

  ThemeData _theme(Brightness b) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: b,
    );
    final light = b == Brightness.light;
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      brightness: b,
      scaffoldBackgroundColor: light ? _lightBg : _darkBg,
      // 卡片统一：无阴影、18 圆角、贴近参考图的「纸片」质感。
      cardTheme: CardThemeData(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: light ? Colors.white : const Color(0xFF1D1E18),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: light ? _lightBg : _darkBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.45),
        thickness: 0.5,
        space: 0.5,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'cytest',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomeShell(),
    );
  }
}
