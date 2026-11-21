import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'ui/home.dart';
import 'ui/ios.dart';
import 'ui/widgets/glass.dart';

class CytestApp extends StatelessWidget {
  const CytestApp({super.key});

  /// 主色：墨黑（只用在行动点与选中态）。
  static const _seed = Color(0xFF111114);

  ThemeData _theme(Brightness b) {
    final light = b == Brightness.light;
    // 单色方案：primary 用墨黑（深色模式反相为浅灰），secondary 同色，
    // 不留任何色相 —— 彩色只由「危险」按钮承担。
    final ink = light ? const Color(0xFF111114) : const Color(0xFFEDEDF0);
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: b)
        .copyWith(
          primary: ink,
          onPrimary: light ? Colors.white : const Color(0xFF111114),
          secondary: ink,
          onSecondary: light ? Colors.white : const Color(0xFF111114),
          // 由 seed 推导出的 surface/onSurface 会带一点蓝紫倾向，
          // 单色方案里必须钉成纯灰阶，否则标题看起来「发蓝」。
          onSurface: ink,
          onSurfaceVariant: const Color(0xFF8E8E93),
          surface: light ? const Color(0xFFFFFFFF) : const Color(0xFF1C1C1E),
          outlineVariant:
              light ? const Color(0xFFE5E5EA) : const Color(0xFF38383A),
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
      // iOS 分组卡：白底 / 深灰卡、22 圆角、无描边。
      cardTheme: CardThemeData(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: light ? const Color(0xFFFFFFFF) : const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Ios.cardRadius),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      dividerTheme: DividerThemeData(
        color: light ? const Color(0xFFE5E5EA) : const Color(0xFF38383A),
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
      // 输入框：iOS 表单风格 —— 灰底圆角、无边框、聚焦时细主色描边。
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        isDense: true,
        fillColor: light ? const Color(0xFFF2F2F7) : const Color(0xFF2C2C2E),
        hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF8E8E93)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Ios.fieldRadius),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Ios.fieldRadius),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Ios.fieldRadius),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      // 弹层 / 对话框：接近不透明的磨砂面，内容可读优先。
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: light ? Colors.white : const Color(0xFF1C1C1E),
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(Ios.cardRadius)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: light ? Colors.white : const Color(0xFF1C1C1E),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Ios.cardRadius),
        ),
      ),
      // 底部导航：交给 GlassBar 包外层，这里只定指示器与透明度。
      // 底部 Tab：iOS 风格（细标签、主色选中）。
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        height: 56,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 10.5,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? (light ? const Color(0xFF111114) : const Color(0xFFEDEDF0))
                : const Color(0xFF8E8E93),
          ),
        ),
      ),
      // 按钮：主按钮用实心主色（玻璃世界里唯一的「实体」行动点），
      // 其余按钮弱化背景，让玻璃层级不被按钮色块切碎。
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Ios.buttonRadius),
          ),
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
