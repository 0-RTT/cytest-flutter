import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'pages/fetch_page.dart';
import 'pages/history_page.dart';
import 'pages/remote_page.dart';
import 'pages/result_page.dart';
import 'pages/settings_page.dart';
import 'pages/test_page.dart';
import 'widgets/glass.dart';

/// 视觉常量：冷灰底 + 白卡 + 岩板蓝（不用绿、不用紫）。
class _C {
  static const card = Color(0xFFFFFFFF);
  static const border = Color(0xFFE5E7EB);
  static const ink = Color(0xFF1F2937);
  static const sub = Color(0xFF6B7280);
  static const accent = Color(0xFF374151);
  static const teal = Color(0xFF2F5D50);
  static const accentSoft = Color(0xFFF3F4F6);
  static const radius = 26.0;
}

/// 主框架：首页 + 设置（底部白色导航栏）。
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
        bottomNavigationBar: _BottomNav(
          index: _index,
          onChanged: (i) => setState(() => _index = i),
        ),
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final items = const [
      (Icons.home_rounded, '首页'),
      (Icons.settings_outlined, '设置'),
    ];
    final active = dark ? const Color(0xFFCBD5E1) : _C.accent;
    final idle = dark ? const Color(0xFF9CA3AF) : _C.sub;

    return Container(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF111214) : _C.card,
        border: Border(
          top: BorderSide(
            color: dark ? const Color(0xFF2A2A2E) : _C.border,
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: InkWell(
                    onTap: () => onChanged(i),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(items[i].$1,
                            size: 21, color: i == index ? active : idle),
                        const SizedBox(height: 3),
                        Text(
                          items[i].$2,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight:
                                i == index ? FontWeight.w600 : FontWeight.w500,
                            color: i == index ? active : idle,
                          ),
                        ),
                      ],
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

/// 首页：标题栏 + 主流程 2+1 + 工具双列。
class _HomeTab extends StatelessWidget {
  const _HomeTab();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final usable = state.usableCount;
    final rows = state.rows;
    final running = state.running;

    return Scaffold(
      backgroundColor: Colors.transparent,
      // 首页没有 AppBar，必须自己避让状态栏（top: true）；
      // 之前写 top: false 是照抄子页面的写法（那些页面有 GlassAppBar 兜着）。
      // 没有 AppBar 就没有系统 UI 样式来源：显式声明状态栏图标明暗，
      // 否则深色模式下白色图标贴在浅色背景上会看不见。
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        ),
        child: SafeArea(
        top: true,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            // ---- 标题栏 ----
            Row(
              children: [
                Text(
                  'cytest',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.6,
                    color: dark ? const Color(0xFFF3F4F6) : _C.ink,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => context.read<AppState>().boot(),
                  tooltip: '刷新状态',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.refresh_rounded,
                      size: 22,
                      color: dark ? const Color(0xFF9CA3AF) : _C.sub),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // ---- 主流程 ----
            _sectionLabel(context, '主流程', trailing: '三阶段流水线'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _stepCard(
                    context,
                    icon: Icons.cloud_download_outlined,
                    title: '获取数据',
                    subtitle: 'Censys 拉候选',
                    onTap: () => _push(context, const FetchPage()),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _stepCard(
                    context,
                    icon: Icons.graphic_eq_rounded,
                    title: '本地测试',
                    subtitle: '延迟 / 速度',
                    onTap: () => _push(context, const TestPage()),
                    running: running,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 03 结果：通栏卡片
            _card(
              context,
              onTap: () => _push(context, const ResultPage()),
              child: Row(
                children: [
                  _iconChip(context, Icons.bar_chart_rounded),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('结果', style: _titleStyle(context)),
                        const SizedBox(height: 3),
                        Text(
                          rows.isEmpty
                              ? '暂无数据 · 跑一轮本地测试'
                              : '$usable 条可用 · 点击查看与导出',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: rows.isEmpty
                              ? _subStyle(context)
                              : _subStyle(context).copyWith(
                                  color: dark
                                      ? const Color(0xFF7FBFA8)
                                      : _C.teal,
                                  fontWeight: FontWeight.w500,
                                ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded,
                      size: 20,
                      color: dark ? const Color(0xFF6B7280) : _C.sub),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ---- 工具 ----
            _sectionLabel(context, '工具'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _toolCard(
                    context,
                    icon: Icons.history_rounded,
                    title: '记录',
                    subtitle: '历史与存档',
                    chevron: true,
                    onTap: () => _push(context, const HistoryPage()),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _toolCard(
                    context,
                    icon: Icons.dns_outlined,
                    title: '远程执行',
                    subtitle: '服务器跑三阶段',
                    dot: true,
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

  // ---------- 组件 ----------

  Widget _sectionLabel(BuildContext context, String text, {String? trailing}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: dark ? const Color(0xFF9CA3AF) : _C.sub,
          ),
        ),
        const Spacer(),
        if (trailing != null)
          Text(trailing,
              style: TextStyle(
                fontSize: 11.5,
                color: dark ? const Color(0xFF6B7280) : _C.sub,
              )),
      ],
    );
  }

  Widget _card(BuildContext context,
      {required Widget child, VoidCallback? onTap}) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final body = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1C1C1E) : _C.card,
        borderRadius: BorderRadius.circular(_C.radius),
        // 参考稿是无边框 + 柔和投影：去掉 1px 描边，靠投影分层，
        // 卡片边缘更干净（描边会让大圆角看起来有「双重轮廓」）。
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1F2937)
                .withValues(alpha: dark ? 0.45 : 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
          BoxShadow(
            color: const Color(0xFF1F2937)
                .withValues(alpha: dark ? 0.30 : 0.03),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
    if (onTap == null) return body;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(_C.radius),
        child: body,
      ),
    );
  }

  Widget _badge(BuildContext context, String text) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tint = dark ? const Color(0xFFCBD5E1) : _C.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: dark ? tint.withValues(alpha: 0.16) : _C.accentSoft,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: tint,
        ),
      ),
    );
  }

  Widget _iconChip(BuildContext context, IconData icon) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tint = dark ? const Color(0xFFCBD5E1) : _C.accent;
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: dark ? tint.withValues(alpha: 0.16) : _C.accentSoft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 20, color: tint),
    );
  }

  TextStyle _titleStyle(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.3,
      color: dark ? const Color(0xFFF3F4F6) : _C.ink,
    );
  }

  TextStyle _subStyle(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return TextStyle(
      fontSize: 12.5,
      height: 1.35,
      color: dark ? const Color(0xFF9CA3AF) : _C.sub,
    );
  }

  /// 主流程前两张：徽章 + 图标 + 标题 + 说明。
  Widget _stepCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool running = false,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tint = dark ? const Color(0xFFCBD5E1) : _C.accent;
    return _card(
      context,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 24, color: tint),
              const Spacer(),
              if (running)
                Container(
                  width: 6,
                  height: 6,
                  decoration:
                      BoxDecoration(color: tint, shape: BoxShape.circle),
                ),
            ],
          ),
          const SizedBox(height: 14),
          const SizedBox(height: 10),
          Text(title, style: _titleStyle(context)),
          const SizedBox(height: 3),
          Text(subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _subStyle(context)),
        ],
      ),
    );
  }

  /// 工具卡片：图标 + 标题 + 说明，右上角可带状态点。
  Widget _toolCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool dot = false,
    bool chevron = false,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return _card(
      context,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _iconChip(context, icon),
              const Spacer(),
              if (dot)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: dark ? const Color(0xFF7FBFA8) : _C.teal,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(title, style: _titleStyle(context)),
          const SizedBox(height: 3),
          Row(
            children: [
              Expanded(
                child: Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _subStyle(context)),
              ),
              if (chevron)
                Icon(Icons.chevron_right_rounded,
                    size: 18,
                    color: dark ? const Color(0xFF6B7280) : _C.sub),
            ],
          ),
        ],
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(GlassRoute(builder: (_) => page));
  }
}
