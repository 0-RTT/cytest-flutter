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
/// 首页内容保持原样：主流程 3 步 + 工具 2 项，文案与跳转一字不改。
/// 换的只是材质——液态玻璃：渐变底上浮着半透明卡片，
/// 按下有缩放反馈，顶栏 / 底栏是磨砂玻璃。
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
        child: Padding(
          // bottom 14 = 包底：卡片圆角与底部导航之间留出呼吸。
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _label(theme, '主流程'),
              const SizedBox(height: 8),
              // 小模块：固定高度，不随屏高拉伸（拉成细长条很难看）。
              // 首页是静止页面，这里开实时模糊；列表页请用默认 blur: false。
              SizedBox(
                height: 120,
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
              // 两块内容之间靠弹性留白分配剩余高度，而不是把卡片拉长。
              const Spacer(flex: 2),
              _label(theme, '工具'),
              const SizedBox(height: 8),
              SizedBox(
                height: 96,
                child: Row(
                  children: [
                    Expanded(
                      child: _ToolTile(
                        icon: Icons.history,
                        title: '记录',
                        subtitle: '历史与存档',
                        onTap: () => _push(context, const HistoryPage()),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ToolTile(
                        icon: Icons.dns_outlined,
                        title: '远程执行',
                        subtitle: '服务器跑三阶段',
                        onTap: () => _push(context, const RemotePage()),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(flex: 3),
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
/// 玻璃材质 + 按下缩放（blur 只在首页这种静止页面开）。
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
    return GlassCard(
      blur: true,
      onTap: onTap,
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
    );
  }
}

/// 工具小卡：图标方块 + 标题 + 说明，与步骤卡同一体量。
class _ToolTile extends StatelessWidget {
  const _ToolTile({
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
    return GlassCard(
      blur: true,
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(9),
            ),
            child:
                Icon(icon, size: 17, color: theme.colorScheme.primary),
          ),
          const Spacer(),
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall),
          const SizedBox(height: 1),
          Flexible(
            child: Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
