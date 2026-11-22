import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 视觉系统：实心卡片 + 柔和渐变底 + 轻量转场。
///
/// **刻意不用 BackdropFilter（毛玻璃）**：它每帧都要 saveLayer + 高斯模糊，
/// 一屏 3~4 块就要付出 3~4 次全屏合成；叠加页面转场时，被移动/淡入的
/// 玻璃还得逐帧重算，表现为「点进子页卡顿 + 画面闪烁」。
/// 现在改成实心卡片：同样的圆角、描边、投影与配色，滚动与转场都是纯
/// 光栅平移，帧率稳定。
///
/// 组件：
/// - [GlassBackground]：全 App 统一的渐变底（静态绘制，不产生逐帧成本）。
/// - [GlassCard]：实心卡 + 细描边 + 柔和投影，可带按压反馈。
/// - [GlassAppBar] / [GlassBar]：透明顶栏 / 底栏 + 高光线。
/// - [GlassPressable]：按下 0.965 缩放 + 轻触感。
/// - [GlassRoute] / [GlassPageTransitionsBuilder]：260ms 淡入 + 3% 上滑。
class Glass {
  Glass._();

  /// 卡片圆角：比 M3 默认更大，接近 iOS 连续曲率的观感。
  static const double cardRadius = 24;

  /// 小组件（统计卡、日志面板）用的小圆角。
  static const double smallRadius = 14;

  /// 描边宽度：物理 1px 左右。
  static const double strokeWidth = 0.8;

  static bool _light(ThemeData theme) => theme.brightness == Brightness.light;

  /// 卡片填充：实心，浅色近白、深色近黑，保证任何背景上都清晰。
  static Color fill(ThemeData theme) =>
      _light(theme) ? const Color(0xFFFFFFFF) : const Color(0xFF1C1C1E);

  /// 卡片描边：实心细线，比渐变描边少一次 shader 计算。
  static Color stroke(ThemeData theme) => _light(theme)
      ? const Color(0xFFE5E7EB)
      : const Color(0xFF2A2A2E);

  /// 顶栏 / 底栏：透明，让渐变底直接透出来（不做任何合成）。
  static Color barFill(ThemeData theme) =>
      _light(theme) ? const Color(0xFFF6F7F9) : const Color(0xFF0B0C0E);

  /// 柔和投影：幅度小、半径大，给「浮起」而不是「贴纸」的感觉。
  /// 不用投影：白卡贴在冷灰底上，1px 浅灰边框已经能分层，
  /// 再加模糊阴影会显得脏（设计稿就是无阴影的）。
  static List<BoxShadow> shadow(ThemeData theme) => [
        BoxShadow(
          color: const Color(0xFF1F2937)
              .withValues(alpha: _light(theme) ? 0.05 : 0.45),
          blurRadius: 10,
          offset: const Offset(0, 2),
        ),
        BoxShadow(
          color: const Color(0xFF1F2937)
              .withValues(alpha: _light(theme) ? 0.03 : 0.30),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
      ];

  /// 细分割线（顶栏底部、底栏顶部的高光线）。
  static BorderSide hairline(ThemeData theme) => BorderSide(
        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
        width: 0.5,
      );
}

/// 全 App 背景：冷灰 `#F6F7F9`（深色 `#0B0C0E`），纯色不渐变。
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Theme.of(context).brightness == Brightness.light
            ? const Color(0xFFF4F5F7)
            : const Color(0xFF0B0C0E),
        child: child,
      );
}

/// 实心卡片：细描边 + 柔和投影 + 大圆角。
///
/// [onTap] 非空时整卡可点，带按下缩放（[GlassPressable]）与涟漪。
/// 列表容器卡可以关掉投影（[shadow] = false），避免长列表边缘发灰。
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.radius = Glass.cardRadius,
    this.onTap,
    this.shadow = true,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final VoidCallback? onTap;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderRadius = BorderRadius.circular(radius);

    Widget content = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Glass.fill(theme),
        borderRadius: borderRadius,
        border: Border.all(
          color: Glass.stroke(theme),
          width: Glass.strokeWidth,
        ),
      ),
      // 透明 Material：ListTile / InkWell 的涟漪画在最近的上层 Material 上。
      // 没有这层，卡片底色会藏在 Ink 与 ListTile 之间，debug 模式直接抛
      // 「ink splashes may be invisible」断言。
      child: Material(
        type: MaterialType.transparency,
        child: onTap == null
            ? child
            : GlassPressable(
                onTap: onTap,
                borderRadius: borderRadius,
                child: child,
              ),
      ),
    );

    if (shadow) {
      content = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: Glass.shadow(theme),
        ),
        child: content,
      );
    }

    return Padding(
      padding: margin ?? EdgeInsets.zero,
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
        clipBehavior:
            widget.borderRadius != null ? Clip.antiAlias : Clip.none,
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

/// 顶栏：透明 + 底部高光线，不做模糊也不做额外合成。
///
/// 不启用 extendBodyBehindAppBar（各页布局规则已经很满，不引入新变量）。
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
    return Container(
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
    );
  }
}

/// 底栏（保存条 / 推送条 / 底部导航的容器）：透明 + 顶部高光线。
class GlassBar extends StatelessWidget {
  const GlassBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: Glass.barFill(theme),
        border: Border(top: Glass.hairline(theme)),
      ),
      child: child,
    );
  }
}

/// 轻量的页面转场：淡入 + 3% 的轻微上滑，260ms。
///
/// 与系统默认的 Zoom（整页缩放 + 阴影）相比：
/// - 不缩放整页，卡片边缘不会抖；
/// - 不加阴影，省掉一次全屏合成；
/// - 时长 260ms，点下去更快有反馈（「跟手」）。
///
/// 只动**新进入**的那一页（返回时它自己反向淡出），底下的页面保持不动，
/// 所以看不到两页同时移动的"重影"。
class GlassPageTransitionsBuilder extends PageTransitionsBuilder {
  const GlassPageTransitionsBuilder();

  /// 260ms：比 M3 FadeForwards 的 450ms 短，接近 iOS 的手感。
  static const Duration duration = Duration(milliseconds: 260);

  @override
  Duration get transitionDuration => duration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.03),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

/// 带「自有背景」的路由。
///
/// 页面 Scaffold 是透明的，背景来自 MaterialApp 最底层那层渐变。转场期间
/// 两页会同时绘制，新页的透明区域会透出旧页卡片，看起来像重影。
/// 这里给**每个页面自己铺一份同样的渐变**：
/// - 转场时新页是实心的，只有一次干净的交叉溶解；
/// - 渐变是静态绘制，会被缓存，不产生逐帧成本。
class GlassRoute<T> extends MaterialPageRoute<T> {
  GlassRoute({
    required super.builder,
    super.settings,
    super.maintainState,
  });

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return GlassBackground(
      child: super.buildPage(context, animation, secondaryAnimation),
    );
  }
}

/// 顶栏/页面上的浅色动作按钮。
///
/// 为什么不用实心深色：整屏是冷灰 + 白卡，一个深色胶囊在顶栏会显得很「重」，
/// 而且和正文的字重抢注意力。这里用「白底 + 1px 浅灰边 + 深灰字」，
/// 需要时靠字重（w600）而不是色块来表达「可点」。
class GlassActionButton extends StatelessWidget {
  const GlassActionButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final light = theme.brightness == Brightness.light;
    final enabled = onPressed != null;
    final ink = light ? const Color(0xFF1F2937) : const Color(0xFFF3F4F6);

    return SizedBox(
      height: 32,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: light ? Colors.white : const Color(0xFF2C2C2E),
          foregroundColor: enabled ? ink : ink.withValues(alpha: 0.4),
          disabledBackgroundColor:
              light ? Colors.white : const Color(0xFF2C2C2E),
          side: BorderSide(color: Glass.stroke(theme)),
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: theme.textTheme.labelLarge?.copyWith(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15),
              const SizedBox(width: 5),
            ],
            Text(label),
          ],
        ),
      ),
    );
  }
}
