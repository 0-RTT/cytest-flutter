import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'ui/home.dart';
import 'ui/widgets/glass.dart';

class CytestApp extends StatelessWidget {
  const CytestApp({super.key});

  /// 主色：墨黑。整屏只有灰阶（冷灰底 + 白卡 + 深灰字），
  /// 不用绿、不用蓝、不用紫 —— 彩色只留给危险操作。
  static const _seed = Color(0xFF374151);

  /// 公开给测试/预览使用：与线上同一套主题。
  static ThemeData buildTheme(Brightness b) => _theme(b);

  static ThemeData _theme(Brightness b) {
    final light = b == Brightness.light;
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: b)
        .copyWith(
          primary: light ? const Color(0xFF374151) : const Color(0xFFCBD5E1),
          onSurface: light ? const Color(0xFF1F2937) : const Color(0xFFF3F4F6),
          onSurfaceVariant: const Color(0xFF6B7280),
          outlineVariant:
              light ? const Color(0xFFE5E7EB) : const Color(0xFF2A2A2E),
        );
    return ThemeData(
      colorScheme: scheme,
      // 全局字体：MiSans（思源/系统黑体偏方正，MiSans 更几何、字重过渡更干净）。
      // 字库只裁了源码用到的字符（见 pubspec），缺字回退系统字体。
      fontFamily: 'MiSans',
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
          borderRadius: BorderRadius.circular(24),
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
      // 转场：**零时长**，点完立刻是新页面。
      //
      // 之前是 260ms 的淡入 + 上滑。在没有 GPU 的机器上一帧要 30~250ms，
      // 这段动画反而变成「卡着慢慢浮上来」；桌面端的操作用户也不期待页面动画。
      // 时长设成 0 之后 Flutter 直接切页，不再请求中间帧。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: InstantPageTransitionsBuilder(),
          TargetPlatform.fuchsia: InstantPageTransitionsBuilder(),
          TargetPlatform.linux: InstantPageTransitionsBuilder(),
          TargetPlatform.windows: InstantPageTransitionsBuilder(),
          TargetPlatform.iOS: InstantPageTransitionsBuilder(),
          TargetPlatform.macOS: InstantPageTransitionsBuilder(),
        },
      ),
      // 输入框：不铺灰底（灰块在灰底+白卡的页面里像补丁），
      // 只留 1px 细边表示「这里是可输入的内腔」，聚焦时才用主色描边。
      inputDecorationTheme: InputDecorationTheme(
        filled: false,
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: light ? const Color(0xFFDDE1E6) : const Color(0xFF3A3A3E)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: light ? const Color(0xFFDDE1E6) : const Color(0xFF3A3A3E)),
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
      // 按钮不再用实心色块：透明底 + 1px 细边 + 深灰字。
      // 色块在灰底/白卡的界面里像一块「补丁」，透明底则与所在容器自然贴合，
      // 「可点」靠边框与字重表达，不靠颜色。
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor:
              light ? const Color(0xFF1F2937) : const Color(0xFFF3F4F6),
          disabledBackgroundColor: Colors.transparent,
          disabledForegroundColor:
              light ? const Color(0xFFB6BCC4) : const Color(0xFF5B6068),
          side: BorderSide(
            color: light ? const Color(0xFFDDE1E6) : const Color(0xFF3A3A3E),
          ),
          elevation: 0,
          shadowColor: Colors.transparent,
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
      // 关掉桌面端默认的滚动条：它在每次程序化 jumpTo（日志自动跟随）时
      // 都会播放一次淡入淡出动画，一帧 30ms 的软件光栅化下就是持续掉帧/吃 CPU。
      // 界面本身就是「无滚动条」的移动端风格，去掉也一致。
      scrollBehavior: const CytestScrollBehavior(),
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

/// 无滚动条的滚动行为（见 MaterialApp.scrollBehavior 的注释）。
class CytestScrollBehavior extends MaterialScrollBehavior {
  const CytestScrollBehavior();

  @override
  Widget buildScrollbar(
          BuildContext context, Widget child, ScrollableDetails details) =>
      child;
}
