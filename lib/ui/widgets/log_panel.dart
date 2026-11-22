import 'package:flutter/material.dart';

import '../phosphor_icons.dart';

import 'glass.dart';

/// 通用日志/输出面板：标题栏 + 独立滚动的内容区。
///
/// 这是页面底部的**独立模块**，调用方负责两件事：
/// 1. 把它放进 `Column` 的 `Expanded` 里（而不是塞进整体 ListView 末尾），
///    否则会形成内外双重滚动，日志区还会被挤到首屏外。
/// 2. 外层 `Padding` 必须给 `bottom` 留白（一般 14）——否则卡片底边贴着
///    屏幕物理边缘，圆角和最后一行会糊在屏幕上，看着像"没包底"。
///
/// 材质：磨砂玻璃（半透明 + 高光描边），**不开** BackdropFilter——
/// 日志是高频重绘表面，实时模糊是白烧电。
/// 诊断计数（性能排查用，正式行为不受影响）。
int logPanelBuilds = 0;

class LogPanel extends StatelessWidget {
  const LogPanel({
    super.key,
    required this.title,
    required this.lines,
    required this.scrollController,
    required this.onCopy,
    this.onJumpToLatest,
    this.running = false,
    this.emptyText = '暂无输出',
    this.showJumpToLatest = true,
    this.copyTooltip = '复制日志',
    this.progress,
    this.progressLabel,
  });

  final String title;
  final List<String> lines;
  final ScrollController scrollController;
  final VoidCallback? onJumpToLatest;
  final Future<void> Function() onCopy;
  final bool running;
  final String emptyText;

  /// 非空时在标题下方画一条进度条（0~1）。
  ///
  /// 为什么放在日志卡片内部：进度和日志讲的是同一件事的两种表达（数字 / 明细），
  /// 拆成两张卡会多占一块首屏高度，而长任务真正要看的是日志。
  final double? progress;

  /// 进度条右侧的紧凑读数（如 `12 / 553`），为空则只画条。
  final String? progressLabel;

  /// 静态内容（如推送预览）不需要「跳到最新」，设 false 隐藏。
  final bool showJumpToLatest;

  /// 复制按钮的提示文案，随用途变化（日志 / 产物内容）。
  final String copyTooltip;

  @override
  Widget build(BuildContext context) {
    logPanelBuilds++;
    final theme = Theme.of(context);
    return GlassCard(
      radius: Glass.smallRadius,
      shadow: false,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 6),
            child: Row(
              children: [
                // 长标题（如「mihomo YAML 预览」）在窄屏必须可省略，
                // 否则标题 + 行数 + 两个按钮会撑破 Row。
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(title,
                            style: theme.textTheme.titleSmall,
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (running) ...[
                        const SizedBox(width: 8),
                        // 这里原来是个不定长 CircularProgressIndicator：
                        // 它会以 60fps 无限重绘整个窗口。在没有 GPU 的机器上
                        // 一帧要 30~300ms，于是「跑测试时 CPU 高」——
                        // 实测开着测试页三阶段 45s 烧掉 **250s CPU**（1169 帧），
                        // 换成静态小圆点后回落到个位数秒。
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                if (lines.isNotEmpty)
                  Text('${lines.length} 行',
                      style: theme.textTheme.labelSmall),
                if (showJumpToLatest)
                  IconButton(
                    onPressed: lines.isEmpty ? null : onJumpToLatest,
                    tooltip: '跳到最新',
                    icon: const Icon(PhosphorIconsRegular.arrowDown, size: 18),
                    visualDensity: VisualDensity.compact,
                  ),
                IconButton(
                  onPressed: lines.isEmpty ? null : () { onCopy(); },
                  tooltip: copyTooltip,
                  icon: const Icon(PhosphorIconsRegular.copy, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          if (progress != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: progress!.clamp(0.0, 1.0),
                        minHeight: 4,
                      ),
                    ),
                  ),
                  if (progressLabel != null && progressLabel!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(progressLabel!, style: theme.textTheme.labelSmall),
                  ],
                ],
              ),
            ),
          Expanded(
            child: Container(
              width: double.infinity,
              // 日志区不再铺一整块灰：大块灰底在「灰底 + 白卡」的界面里
              // 像一块补丁。改成与卡面同色的内腔，只靠上方 1px 分割线与
              // 等宽字体的字色区分层次。
              color: Colors.transparent,
              child: lines.isEmpty
                  ? Center(
                      child: Text(emptyText,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      // 底部 12 让最后一行远离卡片圆角，不再像被切掉
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                      itemCount: lines.length,
                      // 固定行高：省掉每帧的文本测量，日志上千行时差别明显。
                      itemExtent: 18,
                      itemBuilder: (_, i) {
                        final line = lines[i];
                        return Text(
                          line,
                          style: TextStyle(
                            // 不用 monospace：它没有中文字形，每行都要走一次
                            // 「西文等宽 + 系统中文」的字体回退，软件光栅化下
                            // 重新整形很贵。MiSans 自带 ASCII 与中文，一次成型。
                            fontFamily: 'MiSans',
                            fontSize: 11.5,
                            color: line.contains('✗') || line.contains('失败')
                                ? theme.colorScheme.error
                                : line.contains('阶段')
                                    ? theme.colorScheme.primary
                                    : null,
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
