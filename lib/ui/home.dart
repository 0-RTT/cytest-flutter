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
/// 首页按「主流程 → 工具」两段组织：主流程是有先后顺序的三步（抓取 → 测试 →
/// 结果），用带序号的步骤卡表达；工具是随时可进的辅助页。
/// 线路 / proxyip / GitHub / 远程账号都只是配置，统一收进设置页，首页不再占卡位。
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
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
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
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: state.xray.running ? Colors.green : theme.hintColor,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    state.xray.running ? '线路已连接' : '线路未启动',
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      // 底部 SafeArea：外层 HomeShell 的 NavigationBar 已吃掉底部 inset，
      // 这里加一层只为与其它页面保持一致（重复应用 inset 时 SafeArea 取 0，无害）。
      // top: false —— 顶部已由 AppBar 处理。
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: () async => state.boot(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
            children: [
              if (state.rows.isNotEmpty) _SummaryBar(state: state),
              _label(theme, '主流程'),
              const SizedBox(height: 8),
              Row(
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
              const SizedBox(height: 18),
              _label(theme, '工具'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _NavCard(
                      icon: Icons.history,
                      title: '记录',
                      subtitle: '历史与存档',
                      onTap: () => _push(context, const HistoryPage()),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _NavCard(
                      icon: Icons.dns_outlined,
                      title: '远程执行',
                      subtitle: '服务器跑三阶段',
                      onTap: () => _push(context, const RemotePage()),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(top: 8, left: 2),
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

class _SummaryBar extends StatelessWidget {
  const _SummaryBar({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget cell(String label, String value) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.labelSmall),
              const SizedBox(height: 2),
              Text(value, style: theme.textTheme.titleMedium),
            ],
          ),
        );

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            cell('可用', '${state.usableCount}'),
            cell('最快', '${state.fastestSpeed.toStringAsFixed(2)} MiB/s'),
            cell('均延迟', '${state.averageLatency} ms'),
          ],
        ),
      ),
    );
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
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 108,
          child: Padding(
            padding: const EdgeInsets.all(11),
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
                          fontWeight: FontWeight.w600,
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
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavCard extends StatelessWidget {
  const _NavCard({
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
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(icon, size: 24, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
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
            ],
          ),
        ),
      ),
    );
  }
}
