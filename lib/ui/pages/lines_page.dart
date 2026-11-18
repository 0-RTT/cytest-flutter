import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/file_pick.dart';
import '../../state/app_state.dart';

/// 线路与代理：**只做配置**，不承载任何测试动作。
///
/// 这里只负责两件事：
/// 1. VLESS 链接（每行一条，取第一条可解析的）；
/// 2. proxyip 文件（导入/清空，不展示内容）。
///
/// 测速入口已全部移到「结果 → 测试」的 VLESS 测试页（那里能看每条链接的
/// 延迟/速度并多选），本页再放一套只会让人分不清「在哪测」。
/// 运行时自动替换 vless 路径里的回源 `ip:port` 由 XrayProc.start 完成，
/// 本页只需展示当前生效值。
class LinesPage extends StatefulWidget {
  const LinesPage({super.key});

  @override
  State<LinesPage> createState() => _LinesPageState();
}

class _LinesPageState extends State<LinesPage> {
  late final TextEditingController _links;

  @override
  void initState() {
    super.initState();
    _links = TextEditingController(
      text: context.read<AppState>().settings.vlessLinks.join('\n'),
    );
  }

  @override
  void dispose() {
    _links.dispose();
    super.dispose();
  }

  List<String> _lines(String text) =>
      text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  Future<void> _save() async {
    final state = context.read<AppState>();
    state.settings.vlessLinks = _lines(_links.text);
    await state.saveSettings();
    if (mounted) _toast('已保存');
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
      setState(() {});
      _toast('已导入 $count 条 proxyip');
    } on FilePickException catch (e) {
      _toast('导入失败：$e');
    } on Object catch (e) {
      _toast('导入失败：$e');
    }
  }

  Future<void> _clearProxyIps() async {
    await context.read<AppState>().clearProxyIps();
    if (!mounted) return;
    setState(() {});
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

    return Scaffold(
      appBar: AppBar(title: const Text('线路与代理')),
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
                _stat(theme, '状态',
                    state.xray.running ? '已连接' : state.xray.note),
                const SizedBox(width: 10),
                _stat(theme, '端口',
                    state.xray.running ? '${state.xray.port}' : '—'),
                const SizedBox(width: 10),
                _stat(theme, '回源替换',
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
                    Text('每行一条，取第一条可解析的',
                        style: theme.textTheme.labelSmall),
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
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('proxyip', style: theme.textTheme.titleSmall),
                        const Spacer(),
                        Text('已加载 ${state.settings.proxyIps.length} 条',
                            style: theme.textTheme.labelSmall),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '从文件加载，不在此展示内容。测速/抓取时自动替换 VLESS 路径里的'
                      '回源 ip:port，文件里的多条会按成功记录轮换。',
                      style: theme.textTheme.labelSmall,
                    ),
                    const SizedBox(height: 10),
                    // proxyip 文件导入（与原版一致的 SAF 选文件）：
                    // 文件落到 cytest/xray/proxyip.csv，格式是 4 列 CSV，
                    // 与原版 Kotlin 的 ProxyIpRepository 可互换。
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: _importProxyIps,
                          icon: const Icon(Icons.file_open_outlined, size: 18),
                          label: const Text('加载文件'),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: state.settings.proxyIps.isEmpty
                              ? null
                              : _clearProxyIps,
                          child: const Text('清空'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(onPressed: _save, child: const Text('保存')),
            ),
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
