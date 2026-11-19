import 'package:flutter/material.dart';

import 'ui/home.dart';
import 'ui/widgets/glass.dart';

class CytestApp extends StatelessWidget {
  const CytestApp({super.key});

  /// 深青主色：液态玻璃体系里主色只用在「行动点」（按钮、选中态、状态点），
  /// 大面积铺色交给渐变底和半透明白，主色才不会脏。
  static const _seed = Color(0xFF0E7C66);

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
      // 所有 Scaffold 透明：背景统一由 MaterialApp.builder 里的
      // GlassBackground 提供，玻璃卡片才有东西可透。
      scaffoldBackgroundColor: Colors.transparent,
      // 普通卡片统一走「磨砂」材质：半透明 + 顶部高光描边 + 18 圆角。
      // 需要实时模糊的静态卡片请显式用 GlassCard(blur: true)。
      cardTheme: CardThemeData(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: light
            ? Colors.white.withValues(alpha: 0.66)
            : Colors.white.withValues(alpha: 0.07),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: light
                ? Colors.white.withValues(alpha: 0.7)
                : Colors.white.withValues(alpha: 0.12),
            width: 0.6,
          ),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.45),
        thickness: 0.5,
        space: 0.5,
      ),
      // 输入框：半透填充 + 聚焦时主色描边，去掉默认的重边框。
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        isDense: true,
        fillColor: light
            ? Colors.white.withValues(alpha: 0.55)
            : Colors.white.withValues(alpha: 0.06),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      // 弹层 / 对话框：接近不透明的磨砂面，内容可读优先。
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: light
            ? Colors.white.withValues(alpha: 0.96)
            : const Color(0xFF1D1F1A).withValues(alpha: 0.96),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: light
            ? Colors.white.withValues(alpha: 0.96)
            : const Color(0xFF1D1F1A).withValues(alpha: 0.96),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
      // 底部导航：交给 GlassBar 包外层，这里只定指示器与透明度。
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.16),
        height: 62,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      // 按钮：主按钮用实心主色（玻璃世界里唯一的「实体」行动点），
      // 其余按钮弱化背景，让玻璃层级不被按钮色块切碎。
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.primary.withValues(alpha: 0.12),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
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
      // 渐变底在最底层，页面切换时固定不动，内容像玻璃板一样滑过。
      builder: (context, child) =>
          GlassBackground(child: child ?? const SizedBox.shrink()),
      home: const HomeShell(),
    );
  }
}
