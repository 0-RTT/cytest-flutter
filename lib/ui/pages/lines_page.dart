import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/file_pick.dart';
import '../../data/link_test.dart';
import '../../data/xray.dart';
import '../../state/app_state.dart';
import '../widgets/link_test_panel.dart';

/// 线路与代理：VLESS 链接 + proxyip + 链路测速。
///
/// 测速部分已从「逐条起 Xray 记进程启动耗时」换成真正的 TTFB + 吞吐测量
/// （设计 §0：旧实现测的不是延迟，是「谁先起床」）。
class LinesPage extends StatefulWidget {
  const LinesPage({super.key});

  @override
  State<LinesPage> createState() => _LinesPageState();
}

class _LinesPageState extends State<LinesPage> {
  late final TextEditingController _links;
  late final TextEditingController _proxies;

  /// 测速模式，默认自动（先延迟后速度，最省时间的推荐路径）。
  LinkTestMode _mode = LinkTestMode.auto;

  /// 「启动线路」按钮的局部忙碌态（测速忙碌态由 [AppState.linkTestRunning] 表达）。
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>().settings;
    _links = TextEditingController(text: s.vlessLinks.join('\n'));
    _proxies = TextEditingController(text: s.proxyIps.join('\n'));
  }

  @override
  void dispose() {
    _links.dispose();
    _proxies.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    state.settings.vlessLinks = _lines(_links.text);
    state.settings.proxyIps = _lines(_proxies.text);
    await state.saveSettings();
    if (mounted) _toast('已保存');
  }

  List<String> _lines(String text) =>
      text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  Future<void> _start() async {
    final state = context.read<AppState>();
    // 测速期间启动单线路代理会被 XrayProc 拒绝（K4），这里先给出可读提示，
    // 不让用户看到一句冷冰冰的异常。
    if (state.linkTestRunning) {
      _toast('测速进行中，请先停止测速');
      return;
    }
    setState(() => _starting = true);
    try {
      await _save();
      await state.startLine();
      if (mounted) _toast('线路已启动');
    } catch (e) {
      if (mounted) _toast('启动失败：$e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _stop() async {
    if (context.read<AppState>().linkTestRunning) {
      _toast('测速进行中，请先停止测速');
      return;
    }
    await context.read<AppState>().stopLine();
    if (mounted) _toast('已停止');
  }

  /// 测速：交给 [AppState.runLinkTest]，UI 只负责收集链接与展示进度。
  Future<void> _runLinkTest() async {
    final state = context.read<AppState>();
    final links = _lines(_links.text);
    if (links.isEmpty) {
      _toast('先填一条 VLESS 链接');
      return;
    }
    await _save();
    if (!mounted) return;

    // K4 预告：开测会停掉当前单线路代理，用户必须提前知道
    if (state.xray.mode == XrayMode.line) {
      _toast('测速将停止当前代理线路');
    }

    final ok = await state.runLinkTest(links, mode: _mode);
    if (!mounted) return;

    // 一次性消费「代理已被测速停掉」的提示（读一次即清，不会反复弹）
    final notice = state.takeProxyStopNotice();
    if (notice != null) {
      _toast(notice);
    } else if (ok) {
      _toast('测速完成 · ${state.linkOkCount} 条可用');
    } else if (state.linkTestError != null) {
      _toast(state.linkTestError!);
    }
  }

  /// 通过系统文件选择器导入 proxyip 文件（4 列 CSV 或每行 ip:port）。
  ///
  /// 取消不报错（静默 return）；读/解析失败给可读原因 —— 用户既然是从文件导入，
  /// 就必须知道「是选错文件了、还是格式不对」。
  Future<void> _importProxyIps() async {
    final state = context.read<AppState>();
    try {
      final text = await pickTextFile();
      if (text == null) return; // 用户取消
      final count = await state.importProxyIps(text);
      if (!mounted) return;
      setState(() => _proxies.text = state.settings.proxyIps.join('\n'));
      _toast('已导入 $count 条 proxyip');
    } on FilePickException catch (e) {
      _toast('导入失败：$e');
    } on Object catch (e) {
      _toast('导入失败：$e');
    }
  }

  /// 清空 proxyip：删文件 + 清内存 + 清空输入框。
  Future<void> _clearProxyIps() async {
    await context.read<AppState>().clearProxyIps();
    if (!mounted) return;
    setState(() => _proxies.clear());
    _toast('已清空 proxyip 列表');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final testing = state.linkTestRunning;

    return Scaffold(
      appBar: AppBar(
        title: const Text('线路与代理'),
        actions: [
          // 测速期间隐藏「停止线路」：点它会把批量进程杀掉，而 UI 上看起来
          // 像一次正常操作（批量模式不是「线路」，不该给这个入口）。
          if (state.xray.running && !testing)
            TextButton(onPressed: _stop, child: const Text('停止线路')),
          const SizedBox(width: 6),
        ],
      ),
      // 底部 SafeArea：Scaffold 的 body 不会自动避让系统手势条 / 三键导航。
      // top: false —— 顶部已由 AppBar 处理。
      body: SafeArea(
        top: false,
        child: ListView(
          // 底部 24 是纯视觉呼吸：系统手势条已由外层 SafeArea 避让。
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
          children: [
            Row(
              children: [
                _stat(
                    theme,
                    '状态',
                    testing
                        ? '测速中'
                        : (state.xray.running ? '已连接' : state.xray.note)),
                const SizedBox(width: 10),
                _stat(theme, '端口',
                    state.xray.running ? '${state.xray.port}' : '—'),
                const SizedBox(width: 10),
                _stat(theme, 'proxyip',
                    state.xray.proxyIp.isEmpty ? '链接原样' : state.xray.proxyIp),
              ],
            ),
            const SizedBox(height: 14),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('VLESS 链接', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Text('每行一条，取第一条可解析的', style: theme.textTheme.labelSmall),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _links,
                      maxLines: 4,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        // Android 的 monospace 不含完整中文字形，中文备注会显示成方块
                        fontFamilyFallback: <String>['sans-serif'],
                        fontSize: 11.5,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                        hintText:
                            'vless://uuid@host:443?type=xhttp&security=tls&...',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('proxyip 列表', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Text('每行 ip:port，用于替换 ws 路径里的回源地址',
                        style: theme.textTheme.labelSmall),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _proxies,
                      maxLines: 4,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontFamilyFallback: <String>['sans-serif'],
                        fontSize: 11.5,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                        hintText: '104.16.0.1:443',
                      ),
                    ),
                    const SizedBox(height: 8),
                    // proxyip 文件导入（与原版一致的 SAF 选文件）：
                    // 文件落到 cytest/xray/proxyip.csv，格式是 4 列 CSV，
                    // 与原版 Kotlin 的 ProxyIpRepository 可互换。
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: _importProxyIps,
                          icon: const Icon(Icons.file_open_outlined, size: 18),
                          label: const Text('导入文件'),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: _clearProxyIps,
                          child: const Text('清空'),
                        ),
                        const Spacer(),
                        Text(
                          '${_lines(_proxies.text).length} 条',
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        FilledButton(
                          // 测速期间禁用「启动线路」：批量与单线路互斥（K4）
                          onPressed: (_starting || testing) ? null : _start,
                          child: Text(_starting ? '处理中…' : '启动线路'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: testing ? null : _runLinkTest,
                          child: Text(testing ? '测速中…' : '测试全部线路'),
                        ),
                        const Spacer(),
                        TextButton(onPressed: _save, child: const Text('保存')),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text('测速模式', style: theme.textTheme.labelSmall),
                        const SizedBox(width: 10),
                        SegmentedButton<LinkTestMode>(
                          segments: const [
                            ButtonSegment(
                                value: LinkTestMode.latency, label: Text('延迟')),
                            ButtonSegment(
                                value: LinkTestMode.speed, label: Text('速度')),
                            ButtonSegment(
                                value: LinkTestMode.auto, label: Text('自动')),
                          ],
                          selected: <LinkTestMode>{_mode},
                          onSelectionChanged: testing
                              ? null
                              : (s) => setState(() => _mode = s.first),
                          showSelectedIcon: false,
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (state.linkTestError != null) ...[
              const SizedBox(height: 12),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    state.linkTestError!,
                    style: TextStyle(
                      color: theme.colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
            if (state.linkTestRunning || state.linkResults.isNotEmpty) ...[
              const SizedBox(height: 12),
              LinkTestPanel(
                results: state.linkResults,
                stage: state.linkStage,
                running: state.linkTestRunning,
                onCancel: state.cancelLinkTest,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stat(ThemeData theme, String label, String value) => Expanded(
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelSmall),
                const SizedBox(height: 2),
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ),
      );
}
