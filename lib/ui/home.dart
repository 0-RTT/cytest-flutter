import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'ios.dart';
import 'pages/fetch_page.dart';
import 'pages/history_page.dart';
import 'pages/remote_page.dart';
import 'pages/result_page.dart';
import 'pages/settings_page.dart';
import 'pages/test_page.dart';
import 'widgets/glass.dart';

/// 主框架：首页 + 设置 两个 Tab（iOS 底部 Tab Bar）。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return GlassBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: IndexedStack(
          index: _index,
          children: const [
            _HomeTab(),
            SettingsPage(),
          ],
        ),
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
      ),
    );
  }
}

/// 首页：iOS Large Title + Bento 便当盒 + 分组列表（Inset Grouped）。
class _HomeTab extends StatelessWidget {
  const _HomeTab();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final rows = state.rows;
    final usable = state.usableCount;

    // 最低延迟取「可用行」里的最小值（设计稿这块写的是最低，不是平均）。
    var minLatency = 0;
    for (final r in rows) {
      if ((r['Reason'] ?? '').isNotEmpty) continue;
      final v = int.tryParse(r['Latency (ms)'] ?? '') ?? 0;
      if (v > 0 && (minLatency == 0 || v < minLatency)) minLatency = v;
    }
    final fastest = state.fastestSpeed;
    final running = state.running;
    final total = state.progressTotal;
    final pct = total > 0 ? (state.progressCur / total).clamp(0.0, 1.0) : 0.0;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          children: [
            // iOS Large Title + 右侧圆形按钮
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('cytest', style: Ios.largeTitle(context)),
                  const Spacer(),
                  IosCircleButton(
                    icon: Icons.refresh,
                    color: Ios.ink(context),
                    tooltip: '刷新状态',
                    onPressed: () => context.read<AppState>().boot(),
                  ),
                ],
              ),
            ),

            // ---- Bento 便当盒：左大卡 + 右双卡（等高） ----
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 左：可用节点
                  Expanded(
                    child: IosBento(
                      onTap: () => _push(context, const ResultPage()),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Text('可用节点',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Ios.secondary(context),
                                  )),
                              const Spacer(),
                              IosPill(
                                running ? '测试中' : (usable > 0 ? '就绪' : '待测'),
                                dot: true,
                                color: running ? Ios.ink(context) : Ios.secondary(context),
                              ),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                Text('$usable',
                                    style: Ios.metric(context, size: 40)),
                                const SizedBox(width: 4),
                                Text('条', style: Ios.rowSub(context)),
                              ],
                            ),
                          ),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                child: Text(
                                  rows.isEmpty ? '还没有结果' : '共 ${rows.length} 条候选',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Ios.caption(context),
                                ),
                              ),
                              SizedBox(
                                height: 16,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    for (final h in const [8.0, 12.0, 10.0, 14.0, 16.0])
                                      Container(
                                        width: 3,
                                        height: h,
                                        margin: const EdgeInsets.only(left: 3),
                                        decoration: BoxDecoration(
                                          color: IosChart.line(context)
                                              .withValues(alpha: 0.25 + h / 50),
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // 右：最低延迟 / 峰值速率（平分高度，与左卡底边对齐）
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: IosBento(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Text('最低延迟',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: Ios.secondary(context),
                                        )),
                                    const Spacer(),
                                    _iconChip(Icons.bolt, context),
                                  ],
                                ),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: [
                                    Text(minLatency > 0 ? '$minLatency' : '—',
                                        style: Ios.metric(context)),
                                    const SizedBox(width: 3),
                                    Text('ms', style: Ios.caption(context)),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: IosBento(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Text('峰值速率',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: Ios.secondary(context),
                                        )),
                                    const Spacer(),
                                    _iconChip(Icons.download_rounded, context),
                                  ],
                                ),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: [
                                    Text(
                                        fastest > 0
                                            ? fastest.toStringAsFixed(0)
                                            : '—',
                                        style: Ios.metric(context)),
                                    const SizedBox(width: 3),
                                    Text('MiB/s', style: Ios.caption(context)),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // ---- 主操作 ----
            IosPrimaryButton(
              label: running ? '测试进行中…' : '开始本地测试',
              icon: running ? null : Icons.play_arrow_rounded,
              busy: running,
              onPressed:
                  running ? null : () => _push(context, const TestPage()),
            ),

            // 进度（运行时才有）
            if (running) ...[
              const SizedBox(height: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: Ios.card(context),
                  borderRadius: BorderRadius.circular(Ios.buttonRadius),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            state.progressStage.isEmpty
                                ? '准备中…'
                                : state.progressStage,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Ios.rowSub(context)
                                .copyWith(color: Ios.label(context)),
                          ),
                        ),
                        Text('${(pct * 100).round()}%',
                            style: Ios.caption(context)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: total > 0 ? pct : null,
                        minHeight: 4,
                        backgroundColor: Ios.fill(context),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 22),
            const IosSectionTitle('主流程', trailing: '三阶段流水线'),
            IosGroup(children: [
              IosRow(
                icon: Icons.cloud_download_outlined,
                title: '获取数据',
                subtitle: 'Censys 拉候选',
                onTap: () => _push(context, const FetchPage()),
              ),
              IosRow(
                icon: Icons.science_outlined,
                title: '本地测试',
                subtitle: '延迟 / 速度',
                onTap: () => _push(context, const TestPage()),
              ),
              IosRow(
                icon: Icons.bar_chart_rounded,
                title: '结果',
                subtitle: rows.isEmpty ? '暂无数据' : '$usable 条可用',
                onTap: () => _push(context, const ResultPage()),
              ),
            ]),

            const SizedBox(height: 20),
            const IosSectionTitle('工具'),
            IosGroup(children: [
              IosRow(
                icon: Icons.history_rounded,
                title: '记录',
                subtitle: '历史与存档',
                onTap: () => _push(context, const HistoryPage()),
              ),
              IosRow(
                icon: Icons.dns_outlined,
                title: '远程执行',
                subtitle: '服务器跑三阶段',
                onTap: () => _push(context, const RemotePage()),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _iconChip(IconData icon, BuildContext context) => Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: Ios.fill(context),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Icon(icon, size: 14, color: IosChart.line(context)),
      );

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(GlassRoute(builder: (_) => page));
  }
}
