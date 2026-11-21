import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'ui/home.dart';
import 'ui/widgets/glass.dart';

class CytestApp extends StatelessWidget {
  const CytestApp({super.key});

  /// 岩板蓝：只用于「行动点」（选中态、徽章、状态点、主按钮）。
  /// 不用绿、不用紫 —— 整屏是冷灰 + 白 + 一点蓝。
  static const _seed = Color(0xFF2563EB);

  /// 公开给测试/预览使用：与线上同一套主题。
  static ThemeData buildTheme(Brightness b) => _theme(b);

  static ThemeData _theme(Brightness b) {
    final light = b == Brightness.light;
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: b)
        .copyWith(
          primary: light ? const Color(0xFF2563EB) : const Color(0xFF60A5FA),
          onSurface: light ? const Color(0xFF111827) : const Color(0xFFF3F4F6),
          onSurfaceVariant: const Color(0xFF6B7280),
          outlineVariant:
              light ? const Color(0xFFE5E7EB) : const Color(0xFF2A2A2E),
        );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      brightness: b,
      // 所有 Scaffold 透明：背景统一由 MaterialApp.builder 里的
      // GlassBackground 提供，玻璃卡片才有东西可透。
      scaffoldBackgroundColor: Colors.transparent,
      // 普通卡片统一走实心材质：近白填充 + 细描边 + 18 圆角。
      // 刻意不用毛玻璃：BackdropFilter 每帧 saveLayer，转场时逐帧重算，
      // 是「点进子页卡顿 + 闪烁」的根源（见 ui/widgets/glass.dart 顶部说明）。
      // 白卡 + 20 圆角 + 1px 极浅灰边框（不用阴影：靠边框分层更干净）。
      cardTheme: CardThemeData(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: light ? const Color(0xFFFFFFFF) : const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: light ? const Color(0xFFE5E7EB) : const Color(0xFF2A2A2E),
            width: 1,
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
      // 转场：自定义轻量淡入（260ms）。系统默认的 Zoom 会整页缩放并加阴影，
      // 玻璃层每帧被重采样，是「点进子页卡顿 + 闪烁」的主要来源。
      // 本 App 只发 Android（arm64），所以四个平台统一走同一套转场，
      // 不引 cupertino 依赖，也就不存在"两套转场代码各养一套"的问题。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: GlassPageTransitionsBuilder(),
          TargetPlatform.fuchsia: GlassPageTransitionsBuilder(),
          TargetPlatform.linux: GlassPageTransitionsBuilder(),
          TargetPlatform.windows: GlassPageTransitionsBuilder(),
          TargetPlatform.iOS: GlassPageTransitionsBuilder(),
          TargetPlatform.macOS: GlassPageTransitionsBuilder(),
        },
      ),
      // 输入框：半透填充 + 聚焦时主色描边，去掉默认的重边框。
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        isDense: true,
        fillColor: light ? const Color(0xFFF3F4F6) : const Color(0xFF2C2C2E),
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
        backgroundColor: light ? Colors.white : const Color(0xFF1C1C1E),
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: light ? Colors.white : const Color(0xFF1C1C1E),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      // 底部导航：交给 GlassBar 包外层，这里只定指示器与透明度。
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        height: 60,
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
      // 固定简体中文：应用文案本身是中文，系统控件的文案（输入框长按菜单、
      // 返回按钮提示、对话框按钮）也要跟着中文，不能一半中文一半英文。
      // 不加 localizationsDelegates 时 Flutter 用 DefaultMaterialLocalizations，
      // 永远是英文 —— 这不是系统设置问题，是应用缺 delegate。
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // 渐变底在最底层，页面切换时固定不动，内容像玻璃板一样滑过。
      builder: (context, child) =>
          GlassBackground(child: child ?? const SizedBox.shrink()),
      home: const HomeShell(),
    );
  }
}
