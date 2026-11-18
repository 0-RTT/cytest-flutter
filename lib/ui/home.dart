import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'pages/fetch_page.dart';
import 'pages/history_page.dart';
import 'pages/remote_page.dart';
import 'pages/result_page.dart';
import 'pages/settings_page.dart';
import 'pages/test_page.dart';

/// 底部两 Tab：首页 / 设置。
///
/// 首页内容保持原样：主流程 3 步 + 工具 2 项。
/// 只借用参考页的视觉语言——暖灰底、纯白圆角卡片、无描边无阴影、深青点缀——
/// 并让两块内容按屏高弹性铺满，不再全挤在页面上半段。
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
        children: [
          const _HomeTab(),
          const SettingsPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
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
      appBar: AppBar(
        title: const Text('cytest'),
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
        child: Padding(
          // bottom 14 = 包底：卡片圆角与底部导航之间留出呼吸。
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _label(theme, '主流程'),
              const SizedBox(height: 8),
              // 主流程与工具按屏高 5:3 分配，卡片高度跟屏幕走，不留半屏空白。
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    Expanded(
                      child: _FlowStep(
                        step: 1,
                        icon: Icons.cloud_download_outlined,
                        title: '获取数据',
                        subtitle: 'Censys 拉候选',
                        onTap: () => _push(context, const FetchPage()),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _FlowStep(
                        step: 2,
                        icon: Icons.science_outlined,
                        title: '本地测试',
                        subtitle: '延迟 / 速度',
                        onTap: () => _push(context, const TestPage()),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _FlowStep(
                        step: 3,
                        icon: Icons.bar_chart_outlined,
                        title: '结果',
                        subtitle: state.rows.isEmpty
                            ? '暂无数据'
                            : '${state.usableCount} 条可用',
                        onTap: () => _push(context, const ResultPage()),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _label(theme, '工具'),
              const SizedBox(height: 8),
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    Expanded(
                      child: _ToolRow(
                        icon: Icons.history,
                        title: '记录',
                        subtitle: '历史与存档',
                        onTap: () => _push(context, const HistoryPage()),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: _ToolRow(
                        icon: Icons.dns_outlined,
                        title: '远程执行',
                        subtitle: '服务器跑三阶段',
                        onTap: () => _push(context, const RemotePage()),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _lineStatus(ThemeData theme, AppState state) {
    final running = state.xray.running;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: running
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
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
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(top: 2, left: 2),
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

/// 主流程步骤卡：左上角序号 + 右上角图标，底部标题与副标题。
class _FlowStep extends StatelessWidget {
  const _FlowStep({
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
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.colorScheme.primary,
                    ),
                    child: Text(
                      '$step',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Icon(icon, size: 20, color: theme.colorScheme.primary),
                ],
              ),
              const Spacer(),
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Flexible(
                child: Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 工具行卡：图标方块 + 标题/副标题 + 箭头。
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
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon,
                    size: 20, color: theme.colorScheme.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
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
              Icon(Icons.chevron_right,
                  size: 20, color: theme.colorScheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}
