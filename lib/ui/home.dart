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
        // 浮动胶囊导航：参考稿把 Tab 放在一块圆角卡片里，悬浮在内容之上。
        // 用 extendBody 让页面内容透到胶囊下面，视觉上更轻。
        extendBody: true,
        bottomNavigationBar: _FloatingTabBar(
          index: _index,
          onChanged: (i) => setState(() => _index = i),
        ),
      ),
    );
  }
}

/// 首页：大标题 + 图表卡片（曲线 / 环形 / 指标）+ 分组列表 + 浮动胶囊导航。
class _HomeTab extends StatelessWidget {
  const _HomeTab();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final rows = state.rows;
    final usable = state.usableCount;

    var minLatency = 0;
    var sumLatency = 0;
    var latencyCount = 0;
    final speeds = <double>[];
    for (final r in rows) {
      if ((r['Reason'] ?? '').isNotEmpty) continue;
      final lat = int.tryParse(r['Latency (ms)'] ?? '') ?? 0;
      if (lat > 0) {
        if (minLatency == 0 || lat < minLatency) minLatency = lat;
        sumLatency += lat;
        latencyCount++;
      }
      final sp = double.tryParse(r['Speed (MiB/s)'] ?? '') ?? 0;
      if (sp > 0) speeds.add(sp);
    }
    final avgLatency = latencyCount > 0 ? sumLatency ~/ latencyCount : 0;
    final fastest = state.fastestSpeed;
    final avgSpeed =
        speeds.isEmpty ? 0.0 : speeds.reduce((a, b) => a + b) / speeds.length;
    final running = state.running;
    final total = state.progressTotal;
    final pct = total > 0 ? (state.progressCur / total).clamp(0.0, 1.0) : 0.0;

    // 曲线用「最近 12 条可用节点的速度」，越靠右越新（按结果顺序）。
    final curve = speeds.length > 12
        ? speeds.sublist(speeds.length - 12)
        : speeds;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text('首页', style: Ios.largeTitle(context)),
                  const Spacer(),
                  IosCircleButton(
                    icon: Icons.refresh,
                    tooltip: '刷新状态',
                    onPressed: () => context.read<AppState>().boot(),
                  ),
                ],
              ),
            ),

            // ---- 大卡：速度曲线 ----
            IosBento(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.show_chart_rounded,
                          size: 18, color: IosChart.line(context)),
                      const SizedBox(width: 8),
                      Text('测速概览',
                          style: Ios.rowTitle(context)
                              .copyWith(fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Text(
                        speeds.isEmpty
                            ? '暂无数据'
                            : '最高 ${fastest.toStringAsFixed(1)} · 平均 ${avgSpeed.toStringAsFixed(1)} MiB/s',
                        style: Ios.caption(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  IosSparkline(values: curve, height: 84),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text('延迟最低 $minLatency ms · 平均 $avgLatency ms',
                          style: Ios.caption(context)),
                      const Spacer(),
                      Text('${rows.length} 条候选', style: Ios.caption(context)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // ---- 两卡：可用节点环形 / 关键指标 ----
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: IosBento(
                      onTap: () => _push(context, const ResultPage()),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.donut_large_rounded,
                                  size: 16, color: IosChart.line(context)),
                              const SizedBox(width: 6),
                              Text('可用节点',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Ios.secondary(context),
                                  )),
                              const Spacer(),
                              // 状态药丸放这里（卡片顶部），放到环形旁边会被挤没。
                              IosPill(
                                running ? '测试中' : (usable > 0 ? '就绪' : '待测'),
                                dot: true,
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              IosRing(
                                value: rows.isEmpty ? 0 : usable / rows.length,
                                label: '$usable',
                                sub: '共 ${rows.length}',
                                size: 78,
                                stroke: 10,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      rows.isEmpty
                                          ? '还没有结果'
                                          : '可用率 ${(usable * 100 / rows.length).round()}%',
                                      style: Ios.rowSub(context),
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
                  const SizedBox(width: 12),
                  Expanded(
                    child: IosBento(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _metricRow(context, '最低延迟', '$minLatency', 'ms'),
                          Divider(
                            height: 18,
                            thickness: 0.5,
                            color: Ios.separator(context),
                          ),
                          _metricRow(context, '峰值速率',
                              fastest > 0 ? fastest.toStringAsFixed(1) : '—',
                              'MiB/s'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),
            IosPrimaryButton(
              label: running ? '测试进行中…' : '开始本地测试',
              icon: running ? null : Icons.play_arrow_rounded,
              busy: running,
              onPressed:
                  running ? null : () => _push(context, const TestPage()),
            ),

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
                        backgroundColor: IosChart.track(context),
                        color: IosChart.line(context),
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

  Widget _metricRow(
      BuildContext context, String label, String value, String unit) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Ios.secondary(context),
            )),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value, style: Ios.metric(context, size: 22)),
            const SizedBox(width: 3),
            Text(unit, style: Ios.caption(context)),
          ],
        ),
      ],
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(GlassRoute(builder: (_) => page));
  }
}

/// 浮动胶囊导航（参考稿底部那块）。
class _FloatingTabBar extends StatelessWidget {
  const _FloatingTabBar({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  static const _items = [
    (Icons.home_rounded, '首页'),
    (Icons.tune_rounded, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: Ios.card(context),
            borderRadius: BorderRadius.circular(32),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.10),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              for (var i = 0; i < _items.length; i++)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onChanged(i),
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: EdgeInsets.symmetric(
                          horizontal: i == index ? 20 : 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: i == index
                              ? IosChart.fill(context)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _items[i].$1,
                              size: 20,
                              color: i == index
                                  ? IosChart.line(context)
                                  : Ios.secondary(context),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _items[i].$2,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: i == index
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: i == index
                                    ? IosChart.line(context)
                                    : Ios.secondary(context),
                              ),
                            ),
                          ],
                        ),
                      ),
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
