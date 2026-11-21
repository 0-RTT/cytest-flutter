import 'package:flutter/material.dart';

/// iOS 设计系统（HIG + Bento 小卡片）。
///
/// 取值来自设计稿：
/// - 浅色：页面 `#F2F2F7`、卡片 `#FFFFFF`、分割线 `#E5E5EA`、主标签 `#000000`、
///   次级文字 `#8E8E93`、三级 `#C7C7CC`
/// - 深色：页面 `#000000`、卡片 `#1C1C1E`、浮起层 `#2C2C2E`、分割线 `#38383A`
/// - 强调色：靛蓝 `#6366F1`（主操作，取代原来偏「运营商营业厅」的翠绿）、
///   亮蓝 `#0A84FF`（信息/链接）、橙 `#FF9500`（进行中）、红 `#FF3B30`（危险）
/// - 圆角：分组卡 22、便当卡 20、按钮 16、输入框 12
/// - 阴影：`0 1px 2px rgba(0,0,0,0.03)` —— 几乎看不见，靠留白分层
class Ios {
  Ios._();

  // ---- 颜色 ----
  /// 主色：靛蓝。比绿色更中性，配浅灰底与白卡不会显得「廉价促销」。
  static const Color accent = Color(0xFF6366F1);

  /// 次级强调：亮蓝，用于信息型图标（下载、链接、DNS）。
  static const Color blue = Color(0xFF0A84FF);
  static const Color orange = Color(0xFFFF9500);
  static const Color indigo = Color(0xFF5856D6);
  static const Color red = Color(0xFFFF3B30);

  static bool _light(BuildContext c) =>
      Theme.of(c).brightness == Brightness.light;

  static Color bg(BuildContext c) =>
      _light(c) ? const Color(0xFFF2F2F7) : const Color(0xFF000000);

  static Color card(BuildContext c) =>
      _light(c) ? const Color(0xFFFFFFFF) : const Color(0xFF1C1C1E);

  static Color elevated(BuildContext c) =>
      _light(c) ? const Color(0xFFFFFFFF) : const Color(0xFF2C2C2E);

  static Color fill(BuildContext c) =>
      _light(c) ? const Color(0xFFF2F2F7) : const Color(0xFF2C2C2E);

  static Color separator(BuildContext c) =>
      _light(c) ? const Color(0xFFE5E5EA) : const Color(0xFF38383A);

  static Color label(BuildContext c) =>
      _light(c) ? const Color(0xFF000000) : const Color(0xFFFFFFFF);

  static Color secondary(BuildContext c) => const Color(0xFF8E8E93);

  static Color tertiary(BuildContext c) =>
      _light(c) ? const Color(0xFFC7C7CC) : const Color(0xFF5A5A5E);

  // ---- 圆角 ----
  static const double cardRadius = 22;
  static const double bentoRadius = 20;
  static const double buttonRadius = 16;
  static const double fieldRadius = 12;

  /// iOS 卡片阴影：几乎不可见，作用是让白卡在灰底上「立」起来一点。
  static List<BoxShadow> shadow(BuildContext c) => [
        BoxShadow(
          color: Colors.black.withValues(alpha: _light(c) ? 0.04 : 0.5),
          blurRadius: 2,
          offset: const Offset(0, 1),
        ),
      ];

  // ---- 文字 ----
  /// 大标题：32 / w700 / 字距 -0.4（iOS Large Title）。
  static TextStyle largeTitle(BuildContext c) => TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
        height: 1.15,
        color: label(c),
      );

  /// 分组小标题：13 / w500 / 次级灰。
  static TextStyle section(BuildContext c) => TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: secondary(c),
        letterSpacing: 0.1,
      );

  static TextStyle rowTitle(BuildContext c) => TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: label(c),
        letterSpacing: -0.2,
      );

  static TextStyle rowSub(BuildContext c) => TextStyle(
        fontSize: 12.5,
        color: secondary(c),
        height: 1.3,
      );

  /// 数字（等宽，跳动时不抖）。
  static TextStyle metric(BuildContext c, {double size = 22}) => TextStyle(
        fontSize: size,
        fontWeight: FontWeight.w700,
        color: label(c),
        letterSpacing: -0.6,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static TextStyle caption(BuildContext c) =>
      TextStyle(fontSize: 11, color: secondary(c));
}

/// 分组卡（iOS Inset Grouped）：白底、22 圆角、行间 0.5px 分割线。
class IosGroup extends StatelessWidget {
  const IosGroup({super.key, required this.children, this.padding});

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Ios.card(context),
        borderRadius: BorderRadius.circular(Ios.cardRadius),
        boxShadow: Ios.shadow(context),
      ),
      clipBehavior: Clip.antiAlias,
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 0.5,
                thickness: 0.5,
                indent: 62,
                color: Ios.separator(context),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// 分组小标题（左对齐，13pt 次级灰）。
class IosSectionTitle extends StatelessWidget {
  const IosSectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
      child: Row(
        children: [
          Text(text, style: Ios.section(context)),
          const Spacer(),
          if (trailing != null)
            Text(trailing!, style: Ios.caption(context)),
        ],
      ),
    );
  }
}

/// iOS 列表行：36×36 圆角图标徽章 + 标题/副标题 + 右侧内容 + 折叠箭头。
class IosRow extends StatelessWidget {
  const IosRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.iconColor,
    this.iconWidget,
    this.trailing,
    this.onTap,
    this.chevron = true,
    this.dense = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? iconColor;
  final Widget? iconWidget;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool chevron;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = iconColor ?? Ios.blue;
    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: tint.withValues(alpha: 0.06),
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, dense ? 10 : 12, 12, dense ? 10 : 12),
        child: Row(
          children: [
            if (icon != null || iconWidget != null) ...[
              iconWidget ??
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: tint,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, size: 19, color: Colors.white),
                  ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ios.rowTitle(context)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Ios.rowSub(context)),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              DefaultTextStyle.merge(
                style: Ios.caption(context),
                child: trailing!,
              ),
            ],
            if (chevron)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.chevron_right,
                    size: 20, color: Ios.tertiary(context)),
              ),
          ],
        ),
      ),
    );
  }
}

/// 便当盒小卡片。
class IosBento extends StatelessWidget {
  const IosBento({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(14),
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Ios.card(context),
          borderRadius: BorderRadius.circular(Ios.bentoRadius),
          boxShadow: Ios.shadow(context),
        ),
        child: child,
      ),
    );
  }
}

/// 药丸标签（状态 / 计数）。
class IosPill extends StatelessWidget {
  const IosPill(this.text, {super.key, this.color, this.dot = false});

  final String text;
  final Color? color;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Ios.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: tint,
              letterSpacing: -0.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// 主操作按钮（全宽、16 圆角、翠绿实心）。
class IosPrimaryButton extends StatelessWidget {
  const IosPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.color,
    this.busy = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color? color;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Ios.accent;
    return SizedBox(
      height: 48,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: tint,
          disabledBackgroundColor: tint.withValues(alpha: 0.35),
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white70,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Ios.buttonRadius),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(Colors.white),
                ),
              )
            else if (icon != null)
              Icon(icon, size: 18),
            if (busy || icon != null) const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 圆形工具按钮（大标题右侧那种）。
class IosCircleButton extends StatelessWidget {
  const IosCircleButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.color,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = Material(
      color: Ios.fill(context),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(icon, size: 17, color: color ?? Ios.label(context)),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}
