import 'package:flutter/material.dart';

/// 通用日志/输出面板：标题栏 + 独立滚动的内容区。
///
/// 这是页面底部的**独立模块**，调用方负责两件事：
/// 1. 把它放进 `Column` 的 `Expanded` 里（而不是塞进整体 ListView 末尾），
///    否则会形成内外双重滚动，日志区还会被挤到首屏外。
/// 2. 外层 `Padding` 必须给 `bottom` 留白（一般 14）——否则卡片底边贴着
///    屏幕物理边缘，圆角和最后一行会糊在屏幕上，看着像"没包底"。
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
  });

  final String title;
  final List<String> lines;
  final ScrollController scrollController;
  final VoidCallback? onJumpToLatest;
  final Future<void> Function() onCopy;
  final bool running;
  final String emptyText;

  /// 静态内容（如推送预览）不需要「跳到最新」，设 false 隐藏。
  final bool showJumpToLatest;

  /// 复制按钮的提示文案，随用途变化（日志 / 产物内容）。
  final String copyTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          width: 0.5,
        ),
      ),
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
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: theme.colorScheme.primary),
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
                    icon: const Icon(Icons.vertical_align_bottom, size: 18),
                    visualDensity: VisualDensity.compact,
                  ),
                IconButton(
                  onPressed: lines.isEmpty ? null : () { onCopy(); },
                  tooltip: copyTooltip,
                  icon: const Icon(Icons.copy_all_outlined, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerHighest,
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
                      itemBuilder: (_, i) {
                        final line = lines[i];
                        return Text(
                          line,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            // monospace 里没有中文字形，必须回落系统字体
                            fontFamilyFallback: const ['sans-serif'],
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
