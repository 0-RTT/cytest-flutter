import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'pages/fetch_page.dart';
import 'pages/history_page.dart';
import 'pages/remote_page.dart';
import 'pages/result_page.dart';
import 'pages/settings_page.dart';
import 'pages/test_page.dart';
import 'widgets/glass.dart';

/// 底部两 Tab：首页 / 设置。
///
/// 首页内容与之前完全一致：主流程 3 步 + 工具 2 项，文案与跳转不改。
///
/// 排布换了思路：不再「三张小卡并排 + Spacer 硬撑」，而是两组**整宽玻璃卡**，
/// 每行 = 图标 + 标题 / 说明 + 箭头，主流程行额外带序号。
/// - 行式排布没有横向挤压，360dp 窄屏也不必压缩副标题；
/// - 内容整体在可用高度里垂直居中，屏幕再高也不会「上挤下空」；
/// - 与设置页同一套分组语言，两个 Tab 的视觉是连续的。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          _HomeTab(),
          SettingsPage(),
        ],
      ),
      // 底部导航也是一块玻璃：磨砂 + 顶部高光线，页面内容可透上来。
      bottomNavigationBar: GlassBar(
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: '首页',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune_rounded),
              label: '设置',
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeTab extends StatelessWidget {
  const _HomeTab();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: GlassAppBar(
        title: 'cytest',
        automaticallyImplyLeading: false,
        actions: [
          _lineStatus(theme, state),
          IconButton(
            onPressed: () => context.read<AppState>().boot(),
            tooltip: '刷新状态',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.refresh, size: 20),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 内容少（5 行）但屏幕高度差异大：
            // - 高屏：整块内容垂直居中，上下留白均等，不再"上挤下空"；
            // - 矮屏 / 横屏：内容超过可用高度时自动变成可滚动，不会溢出。
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (constraints.maxHeight - 24).clamp(0, 9999),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 4),
                    _label(theme, '主流程'),
                    const SizedBox(height: 8),
                    GlassCard(
                      blur: true,
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          _StepRow(
                            step: 1,
                            icon: Icons.cloud_download_outlined,
                            title: '获取数据',
                            subtitle: 'Censys 拉候选',
                            onTap: () => _push(context, const FetchPage()),
                          ),
                          _divider(theme),
                          _StepRow(
                            step: 2,
                            icon: Icons.science_outlined,
                            title: '本地测试',
                            subtitle: '延迟 / 速度',
                            onTap: () => _push(context, const TestPage()),
                          ),
                          _divider(theme),
                          _StepRow(
                            step: 3,
                            icon: Icons.bar_chart_outlined,
                            title: '结果',
                            subtitle: state.rows.isEmpty
                                ? '暂无数据'
                                : '${state.usableCount} 条可用',
                            onTap: () => _push(context, const ResultPage()),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    _label(theme, '工具'),
                    const SizedBox(height: 8),
                    GlassCard(
                      blur: true,
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          _ToolRow(
                            icon: Icons.history,
                            title: '记录',
                            subtitle: '历史与存档',
                            onTap: () => _push(context, const HistoryPage()),
                          ),
                          _divider(theme),
                          _ToolRow(
                            icon: Icons.dns_outlined,
                            title: '远程执行',
                            subtitle: '服务器跑三阶段',
                            onTap: () => _push(context, const RemotePage()),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 行间分割线：从图标右侧起画，不切断左侧图标列。
  Widget _divider(ThemeData theme) => Divider(
        height: 0.5,
        thickness: 0.5,
        indent: 64,
        endIndent: 14,
        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
      );

  Widget _lineStatus(ThemeData theme, AppState state) {
    final running = state.xray.running;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: running
              ? theme.colorScheme.primary.withValues(alpha: 0.14)
              : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: running
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              running ? '线路已连接' : '线路未启动',
              style: theme.textTheme.labelSmall?.copyWith(
                color: running
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Text(
          text,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 1.2,
          ),
        ),
      );

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }
}

/// 图标方块：主色微光底 + 主色图标，是每一行左侧的视觉锚点。
class _IconTile extends StatelessWidget {
  const _IconTile({required this.icon});

  final IconData icon;

  /// 尺寸写死 40：主流程行与工具行同高，视觉才对得齐。
  static const double size = 40;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.10),
          width: 0.5,
        ),
      ),
      child: Icon(icon, size: size * 0.48, color: theme.colorScheme.primary),
    );
  }
}

/// 主流程行：序号徽标 + 图标 + 标题 / 说明 + 箭头。
class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.step,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final int step;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 11, 8, 11),
        child: Row(
          children: [
            _IconTile(icon: icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      // 序号用小程序徽标，和标题同一行：一眼看出步骤顺序，
                      // 又不像「大数字」那样抢走标题的份量。
                      Container(
                        width: 16,
                        height: 16,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.colorScheme.primary,
                        ),
                        child: Text(
                          '$step',
                          style: TextStyle(
                            fontSize: 10,
                            height: 1,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right,
                size: 20, color: theme.colorScheme.outline),
          ],
        ),
      ),
    );
  }
}

/// 工具行：与主流程行同构，只是没有序号。
class _ToolRow extends StatelessWidget {
  const _ToolRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 11, 8, 11),
        child: Row(
          children: [
            _IconTile(icon: icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right,
                size: 20, color: theme.colorScheme.outline),
          ],
        ),
      ),
    );
  }
}
