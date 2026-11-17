import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/github.dart';
import '../../data/node_template.dart';
import '../../state/app_state.dart';

class ResultPage extends StatelessWidget {
  const ResultPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    if (state.rows.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('结果')),
        body: Center(
          child: Text('还没有结果，先跑一次本地测试',
              style: TextStyle(color: theme.hintColor)),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('结果 · ${state.rows.length} 条'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) => _onAction(context, v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'csv', child: Text('导出 CSV（复制）')),
              PopupMenuItem(value: 'sub', child: Text('生成订阅（复制）')),
              PopupMenuItem(value: 'mihomo', child: Text('生成 mihomo（复制）')),
              PopupMenuItem(value: 'github', child: Text('推送到 GitHub')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Row(
              children: [
                _stat(theme, '可用', '${state.usableCount}'),
                const SizedBox(width: 10),
                _stat(theme, '最快', '${state.fastestSpeed.toStringAsFixed(2)} MiB/s'),
                const SizedBox(width: 10),
                _stat(theme, '均延迟', '${state.averageLatency} ms'),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: state.rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = state.rows[i];
                final ok = (r['Reason'] ?? '').isEmpty;
                final speed = double.tryParse(r['Speed (MiB/s)'] ?? '') ?? 0;
                return ListTile(
                  dense: true,
                  leading: SizedBox(
                    width: 28,
                    child: Text('${i + 1}',
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
                  ),
                  title: Text('${r['IP']}:${r['Port']}',
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                  subtitle: ok
                      ? Text('${r['Latency (ms)']} ms',
                          style: TextStyle(fontSize: 11, color: theme.hintColor))
                      : Text(r['Reason'] ?? '',
                          style: TextStyle(fontSize: 11, color: theme.hintColor)),
                  trailing: ok
                      ? Text(
                          speed > 0 ? '${speed.toStringAsFixed(2)} MiB/s' : '—',
                          style: TextStyle(color: theme.colorScheme.primary, fontSize: 12),
                        )
                      : const SizedBox.shrink(),
                );
              },
            ),
          ),
        ],
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
                Text(value, style: theme.textTheme.titleSmall),
              ],
            ),
          ),
        ),
      );

  Future<void> _onAction(BuildContext context, String action) async {
    final state = context.read<AppState>();
    final targets = state.usableTargets.map((e) => '${e.$1}:${e.$2}').toList();
    if (targets.isEmpty) {
      _toast(context, '没有可用节点');
      return;
    }

    switch (action) {
      case 'csv':
        final buf = StringBuffer('IP,Port,Latency (ms),Speed (MiB/s),Reason\n');
        for (final r in state.rows) {
          buf.writeln('${r['IP']},${r['Port']},${r['Latency (ms)']},${r['Speed (MiB/s)']},${r['Reason']}');
        }
        await Clipboard.setData(ClipboardData(text: buf.toString()));
        _toast(context, 'CSV 已复制到剪贴板');
        break;

      case 'sub':
        final v = state.primaryLine;
        if (v == null) {
          _toast(context, '先在「线路与代理」填一条 vless 链接');
          return;
        }
        final template = state.settings.vlessLinks.first;
        final nodes = expandTemplate(template, targets);
        final body = subscription(nodes);
        await Clipboard.setData(ClipboardData(text: body));
        _toast(context, '订阅已复制（${nodes.length} 个节点，base64）');
        break;

      case 'mihomo':
        final v = state.primaryLine;
        if (v == null) {
          _toast(context, '先在「线路与代理」填一条 vless 链接');
          return;
        }
        final yaml = buildMihomoYaml(v, targets);
        if (yaml.isEmpty) {
          _toast(context, '生成失败：候选地址无法解析');
          return;
        }
        await Clipboard.setData(ClipboardData(text: yaml));
        _toast(context, 'mihomo 配置已复制（${targets.length} 个节点）');
        break;

      case 'github':
        final v = state.primaryLine;
        if (v == null) {
          _toast(context, '先在「线路与代理」填一条 vless 链接');
          return;
        }
        final body = subscription(expandTemplate(state.settings.vlessLinks.first, targets));
        try {
          final path = await GitHub.push(
            token: state.settings.githubToken,
            repo: state.settings.githubRepo,
            path: state.settings.githubPath,
            content: body,
          );
          _toast(context, '已推送到 $path');
        } catch (e) {
          _toast(context, '推送失败：$e');
        }
        break;
    }
  }

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }
}
