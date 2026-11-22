import 'package:flutter/material.dart';

import 'phosphor_icons.dart';
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

  /// 运行中指示点（系统绿）。只做「正在跑」的信号，不参与品牌配色。
  static const live = Color(0xFF34C759);
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
      (PhosphorIconsRegular.house, '首页'),
      (PhosphorIconsRegular.gear, '设置'),
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
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                    color: dark ? const Color(0xFFF3F4F6) : _C.ink,
                  ),
                ),
                const Spacer(),
              ],
            ),
            const SizedBox(height: 14),

            // ---- 主流程 ----
            _sectionLabel(context, '主流程'),
            const SizedBox(height: 8),
            // 三步都是通栏长条：同一套视觉，扫读顺序也更清楚。
            _wideCard(
              context,
              icon: PhosphorIconsRegular.cloudArrowDown,
              title: '获取数据',
              subtitle: 'Censys 拉候选',
              onTap: () => _push(context, const FetchPage()),
              running: state.fetching,
            ),
            const SizedBox(height: 10),
            _wideCard(
              context,
              icon: PhosphorIconsRegular.waveform,
              title: '本地测试',
              subtitle: '延迟 / 速度',
              onTap: () => _push(context, const TestPage()),
              running: state.running,
            ),
            const SizedBox(height: 10),
            _wideCard(
              context,
              icon: PhosphorIconsRegular.hardDrives,
              title: '远程测试',
              subtitle: '服务器跑三阶段',
              onTap: () => _push(context, const RemotePage()),
              running: state.remoteRunning,
            ),

            const SizedBox(height: 20),

            // ---- 工具 ----
            _sectionLabel(context, '工具'),
            const SizedBox(height: 8),
            // 等高：两张卡内容行数不同（结果有长说明），不拉平会一高一矮。
            IntrinsicHeight(
              child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _toolCard(
                    context,
                    icon: PhosphorIconsRegular.chartBar,
                    title: '结果',
                    subtitle: rows.isEmpty ? '暂无数据' : '$usable 条可用',
                    highlight: rows.isNotEmpty,
                    onTap: () => _push(context, const ResultPage()),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _toolCard(
                    context,
                    icon: PhosphorIconsRegular.clockCounterClockwise,
                    title: '记录',
                    subtitle: '历史与存档',
                    chevron: true,
                    onTap: () => _push(context, const HistoryPage()),
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

  // ---------- 组件 ----------

  Widget _sectionLabel(BuildContext context, String text) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Text(
          text,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: dark ? const Color(0xFF9CA3AF) : _C.sub,
          ),
        ),
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

  TextStyle _titleStyle(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return TextStyle(
      fontSize: 14.5,
      fontWeight: FontWeight.w500,
      letterSpacing: -0.1,
      color: dark ? const Color(0xFFF3F4F6) : _C.ink,
    );
  }

  TextStyle _subStyle(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return TextStyle(
      fontSize: 12,
      height: 1.32,
      color: dark ? const Color(0xFF9CA3AF) : _C.sub,
    );
  }

  /// 通栏卡：图标 + 标题 / 说明 + 箭头（远程测试用）。
  Widget _wideCard(
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
      child: Row(
        children: [
          Icon(icon, size: 20, color: tint),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: _titleStyle(context)),
                const SizedBox(height: 3),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _subStyle(context)),
              ],
            ),
          ),
          if (running)
            Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF30D158) : _C.live,
                shape: BoxShape.circle,
              ),
            ),
          Icon(PhosphorIconsRegular.caretRight,
              size: 16,
              color: dark ? const Color(0xFF6B7280) : _C.sub),
        ],
      ),
    );
  }

  /// 工具卡片：图标 + 标题 + 说明。
  Widget _toolCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool chevron = false,
    bool highlight = false,
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
              Icon(icon, size: 19, color: tint),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _titleStyle(context)),
              ),
              if (chevron)
                Icon(PhosphorIconsRegular.caretRight,
                    size: 16,
                    color: dark ? const Color(0xFF6B7280) : _C.sub),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 27),
            child: Text(subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: highlight
                    ? _subStyle(context).copyWith(
                        color: dark ? const Color(0xFF7FBFA8) : _C.teal,
                        fontWeight: FontWeight.w500,
                      )
                    : _subStyle(context)),
          ),
        ],
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(GlassRoute(builder: (_) => page));
  }
}
