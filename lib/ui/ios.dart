import 'package:flutter/material.dart';

/// iOS 设计系统（HIG + Bento 小卡片）。
///
/// 取值来自设计稿：
/// - 浅色：页面 `#F2F2F7`、卡片 `#FFFFFF`、分割线 `#E5E5EA`、主标签 `#000000`、
///   次级文字 `#8E8E93`、三级 `#C7C7CC`
/// - 深色：页面 `#000000`、卡片 `#1C1C1E`、浮起层 `#2C2C2E`、分割线 `#38383A`
/// - 强调：**墨黑**。整屏只有灰阶 + 一个主按钮，彩色只留给「危险」。
///   彩色图标徽章会让列表看起来像应用商店首页；单色反而更耐看，也更像系统原生。
/// - 圆角：分组卡 22、便当卡 20、按钮 16、输入框 12
/// - 阴影：`0 1px 2px rgba(0,0,0,0.03)` —— 几乎看不见，靠留白分层
class Ios {
  Ios._();

  // ---- 颜色 ----
  /// 主色（墨黑）：浅色 `#111114`，深色反相为浅灰 —— 保证按钮对比度始终够。
  static Color ink(BuildContext c) =>
      _light(c) ? const Color(0xFF111114) : const Color(0xFFEDEDF0);

  /// 墨黑上的文字色。
  static Color onInk(BuildContext c) =>
      _light(c) ? const Color(0xFFFFFFFF) : const Color(0xFF111114);

  /// 唯一的彩色：危险操作（删除、错误）。
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
    // 默认不再上色：灰底 + 墨黑图标，色块只留给调用方显式指定。
    final tint = iconColor;
    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Ios.label(context).withValues(alpha: 0.05),
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
                      color: tint ?? Ios.fill(context),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon,
                        size: 19,
                        color: tint == null
                            ? Ios.label(context)
                            : Ios.onInk(context)),
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
    final tint = color ?? Ios.secondary(context);
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
          // 药丸可能被塞进很窄的列里：允许收缩并省略，不要撑破父级。
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: tint,
                letterSpacing: -0.1,
              ),
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
    final tint = color ?? Ios.ink(context);
    final fg = Ios.onInk(context);
    return SizedBox(
      height: 48,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: tint,
          disabledBackgroundColor: tint.withValues(alpha: 0.35),
          foregroundColor: fg,
          disabledForegroundColor: fg.withValues(alpha: 0.7),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Ios.buttonRadius),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
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

/// 数据色：去饱和的深青（参考稿里的曲线色）。
///
/// 只用于**图表**（曲线、环形、柱），不用于按钮 —— 主操作保持墨黑，
/// 这样页面只有一个「深色重点」，不会因为图表配色显得花。
class IosChart {
  IosChart._();

  static Color line(BuildContext c) => Theme.of(c).brightness == Brightness.light
      ? const Color(0xFF2E5B4F)
      : const Color(0xFF8FC7B4);

  static Color fill(BuildContext c) => Theme.of(c).brightness == Brightness.light
      ? const Color(0xFFCFE3DA)
      : const Color(0xFF24443C);

  static Color track(BuildContext c) => Theme.of(c).brightness == Brightness.light
      ? const Color(0xFFE3EDE8)
      : const Color(0xFF2C2C2E);
}

/// 迷你折线图（CATR 平滑 + 底部渐隐填充）。
///
/// 只有一条线、没有坐标轴：它的作用是「一眼看出波动形状」，
/// 精确数值由旁边的文字负责。
class IosSparkline extends StatelessWidget {
  const IosSparkline({
    super.key,
    required this.values,
    this.height = 72,
  });

  final List<double> values;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (values.length < 2) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text('数据不足', style: Ios.caption(context)),
        ),
      );
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparkPainter(
          values: values,
          line: IosChart.line(context),
          fill: IosChart.fill(context),
        ),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({required this.values, required this.line, required this.fill});

  final List<double> values;
  final Color line;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final minV = values.reduce((a, b) => a < b ? a : b);
    final span = (maxV - minV).abs() < 0.001 ? 1.0 : (maxV - minV);

    final pts = <Offset>[];
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final norm = (values[i] - minV) / span;
      final y = size.height - 6 - norm * (size.height - 18);
      pts.add(Offset(x, y));
    }

    // 平滑曲线：相邻点用控制点连线（简化的 Catmull-Rom）
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 0; i < pts.length - 1; i++) {
      final p0 = pts[i];
      final p1 = pts[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      path.cubicTo(midX, p0.dy, midX, p1.dy, p1.dx, p1.dy);
    }

    // 填充：曲线下方渐隐
    final fillPath = Path.from(path)
      ..lineTo(pts.last.dx, size.height)
      ..lineTo(pts.first.dx, size.height)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [fill.withValues(alpha: 0.85), fill.withValues(alpha: 0.05)],
        ).createShader(Offset.zero & size),
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = line,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.values != values || old.line != line;
}

/// 环形进度（可用/总数）。
class IosRing extends StatelessWidget {
  const IosRing({
    super.key,
    required this.value,
    this.size = 84,
    this.stroke = 11,
    this.label,
    this.sub,
  });

  /// 0~1。
  final double value;
  final double size;
  final double stroke;
  final String? label;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size.square(size),
            painter: _RingPainter(
              value: v,
              stroke: stroke,
              track: IosChart.track(context),
              arc: IosChart.line(context),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label ?? '${(v * 100).round()}%',
                  style: Ios.metric(context, size: 19)),
              if (sub != null) Text(sub!, style: Ios.caption(context)),
            ],
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.value,
    required this.stroke,
    required this.track,
    required this.arc,
  });

  final double value;
  final double stroke;
  final Color track;
  final Color arc;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = (size.width - stroke) / 2;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );
    if (value <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -1.5708, // 12 点方向起
      6.2832 * value,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = arc,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.arc != arc || old.stroke != stroke;
}
