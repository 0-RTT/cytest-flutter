import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 液态玻璃（Liquid Glass）视觉系统。
///
/// 这一层只承载「材质」，不承载任何业务：
/// - [GlassBackground]：全 App 统一的渐变底 + 两团低饱和色晕。
///   毛玻璃必须有「背后有东西可模糊」的前提，纯色底下 blur 是无效开销。
/// - [GlassCard]：半透明填充 + 上亮下暗的渐变描边 + 柔和投影，
///   可选 BackdropFilter 模糊。模糊是逐帧成本，只在静止页面开（首页），
///   列表 / 日志这类高频重绘的表面走半透明填充即可（视觉上同样是玻璃）。
/// - [GlassAppBar] / [GlassBar]：顶栏与底部操作条的磨砂材质。
/// - [GlassPressable]：按下 0.965 缩放 + 轻触感，让「跟手」落在指尖上。
class Glass {
  Glass._();

  /// 卡片圆角：比 M3 默认更大，接近 iOS 连续曲率的观感。
  static const double cardRadius = 22;

  /// 小组件（统计卡、标签）用的小圆角。
  static const double smallRadius = 16;

  /// 描边宽度：物理 1px 左右，太粗会像「框」而不是「玻璃边缘」。
  static const double strokeWidth = 0.6;

  static bool _light(ThemeData theme) =>
      theme.brightness == Brightness.light;

  /// 玻璃填充色：浅主题靠白色透光，深主题靠白色微光。
  static Color fill(ThemeData theme, {double? alpha}) => _light(theme)
      ? Colors.white.withValues(alpha: alpha ?? 0.62)
      : Colors.white.withValues(alpha: alpha ?? 0.075);

  /// 顶栏 / 底栏的填充（比卡片更实一点，保证文字可读）。
  static Color barFill(ThemeData theme) => _light(theme)
      ? Colors.white.withValues(alpha: 0.66)
      : const Color(0xFF161814).withValues(alpha: 0.62);

  /// 渐变描边：顶部亮、底部暗，模拟光从上方打在玻璃边缘。
  static LinearGradient strokeGradient(ThemeData theme) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: _light(theme)
            ? [
                Colors.white.withValues(alpha: 0.85),
                Colors.white.withValues(alpha: 0.25),
              ]
            : [
                Colors.white.withValues(alpha: 0.20),
                Colors.white.withValues(alpha: 0.06),
              ],
        stops: const [0.0, 0.5],
      );

  /// 柔和投影：幅度小、半径大，给「浮起」而不是「贴纸」的感觉。
  static List<BoxShadow> shadow(ThemeData theme) => [
        BoxShadow(
          color: Colors.black
              .withValues(alpha: _light(theme) ? 0.06 : 0.30),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ];

  /// 细分割线（顶栏底部、底栏顶部的高光线）。
  static BorderSide hairline(ThemeData theme) => BorderSide(
        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
        width: 0.5,
      );
}

/// 全 App 背景：浅暖灰渐变 + 青 / 暖两团色晕。
///
/// 挂在 MaterialApp.builder 的最底层（所有 Scaffold 设透明底），
/// 让玻璃卡片有真实的颜色可以透；色晕透明度刻意压低，文字区不受干扰。
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: light
              ? const [Color(0xFFF4F3EE), Color(0xFFEAE9E2)]
              : const [Color(0xFF151713), Color(0xFF0C0E0C)],
        ),
      ),
      child: Stack(
        children: [
          // 顶部偏右：主色色晕（玻璃顶栏和上半屏卡片主要透这团）。
          Positioned(
            top: -140,
            right: -100,
            width: 340,
            height: 340,
            child: _blob(primary.withValues(alpha: light ? 0.16 : 0.22)),
          ),
          // 底部偏左：暖色色晕，避免整页只有青色调显得冷。
          Positioned(
            bottom: -120,
            left: -110,
            width: 320,
            height: 320,
            child: _blob(const Color(0xFFC9A86A)
                .withValues(alpha: light ? 0.13 : 0.09)),
          ),
          child,
        ],
      ),
    );
  }

  Widget _blob(Color color) => Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
          ),
        ),
      );
}

/// 玻璃卡片。
///
/// 结构（从外到内）：渐变描边壳 → 圆角裁剪 → BackdropFilter（可选）→
/// 半透明填充 → 内容。[blur] 只在静止页面上开（首页），列表内请关掉——
/// BackdropFilter 是逐帧 saveLayer，滚动列表里开会让低端机掉帧。
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.radius = Glass.cardRadius,
    this.blur = false,
    this.fillAlpha,
    this.onTap,
    this.shadow = true,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;

  /// 是否对背景做实时模糊。默认关： translucent 填充在渐变底上已经足够「玻璃」。
  final bool blur;

  /// 覆盖默认填充透明度（浅主题 0.62 / 深主题 0.075）。
  final double? fillAlpha;

  /// 非空时整卡可点：带按下缩放反馈（[GlassPressable]）与 InkWell 涟漪。
  final VoidCallback? onTap;

  /// 列表容器卡（结果列表等）可以关掉投影，避免长列表边缘发灰。
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outerRadius = BorderRadius.circular(radius);
    final innerRadius = BorderRadius.circular(radius - Glass.strokeWidth);

    Widget content = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Glass.fill(theme, alpha: fillAlpha),
        borderRadius: innerRadius,
      ),
      // 透明 Material：ListTile / InkWell 的涟漪画在最近的上层 Material 上。
      // 没有这层，玻璃填充的 DecoratedBox 会藏在 Ink 与 ListTile 之间，
      // debug 模式直接抛「ink splashes may be invisible」断言。
      child: Material(
        type: MaterialType.transparency,
        child: onTap == null
            ? child
            : GlassPressable(
                onTap: onTap,
                borderRadius: innerRadius,
                child: child,
              ),
      ),
    );

    content = ClipRRect(
      borderRadius: innerRadius,
      child: blur
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: content,
            )
          : content,
    );

    return Container(
      margin: margin,
      padding: const EdgeInsets.all(Glass.strokeWidth),
      decoration: BoxDecoration(
        borderRadius: outerRadius,
        gradient: Glass.strokeGradient(theme),
        boxShadow: shadow ? Glass.shadow(theme) : null,
      ),
      child: content,
    );
  }
}

/// 按下反馈：缩小到 0.965，110ms easeOutCubic 回弹，附轻触感。
///
/// 「跟手」的核心是**按下第一帧就有可见变化**（而不是等涟漪扩散），
/// 所以用 onHighlightChanged 驱动缩放——手指落下的同一帧就开始缩。
class GlassPressable extends StatefulWidget {
  const GlassPressable({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius? borderRadius;

  @override
  State<GlassPressable> createState() => _GlassPressableState();
}

class _GlassPressableState extends State<GlassPressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _down ? 0.965 : 1.0,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOutCubic,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: widget.borderRadius,
        clipBehavior: widget.borderRadius != null
            ? Clip.antiAlias
            : Clip.none,
        child: InkWell(
          onTap: widget.onTap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  widget.onTap!();
                },
          onHighlightChanged: (v) => setState(() => _down = v),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 毛玻璃顶栏：半透明 + 背景模糊 + 底部高光线。
///
/// 不启用 extendBodyBehindAppBar（各页布局规则已经很满，不引入新变量），
/// 模糊的是页面渐变底，观感仍然是「浮在色晕上的一层玻璃」。
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassAppBar({
    super.key,
    this.title,
    this.titleWidget,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.centerTitle = false,
  });

  final String? title;
  final Widget? titleWidget;
  final List<Widget>? actions;
  final Widget? leading;
  final bool automaticallyImplyLeading;
  final bool centerTitle;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: Glass.barFill(theme),
            border: Border(bottom: Glass.hairline(theme)),
          ),
          child: AppBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            centerTitle: centerTitle,
            automaticallyImplyLeading: automaticallyImplyLeading,
            leading: leading,
            title: titleWidget ?? Text(title ?? ''),
            actions: actions,
          ),
        ),
      ),
    );
  }
}

/// 毛玻璃底栏（保存条 / 推送条 / 底部导航的容器）。
class GlassBar extends StatelessWidget {
  const GlassBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: Glass.barFill(theme),
            border: Border(top: Glass.hairline(theme)),
          ),
          child: child,
        ),
      ),
    );
  }
}
