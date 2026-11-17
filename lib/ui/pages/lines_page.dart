import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings.dart';
import '../../data/vless.dart';
import '../../state/app_state.dart';

/// 线路与代理：VLESS 链接 + proxyip，与 Android 端「线路与代理」同构。
class LinesPage extends StatefulWidget {
  const LinesPage({super.key});

  @override
  State<LinesPage> createState() => _LinesPageState();
}

class _LinesPageState extends State<LinesPage> {
  late final TextEditingController _links;
  late final TextEditingController _proxies;
  bool _busy = false;
  List<(String, String)> _probeRows = const [];

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
    state.settings.vlessLinks = _links.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    state.settings.proxyIps = _proxies.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    await state.saveSettings();
    if (mounted) _toast('已保存');
  }

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      await _save();
      await context.read<AppState>().startLine();
      if (mounted) _toast('线路已启动');
    } catch (e) {
      if (mounted) _toast('启动失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    await context.read<AppState>().stopLine();
    if (mounted) _toast('已停止');
  }

  /// 批量测试所有链接：逐个起 Xray + 走 gstatic 探活。
  Future<void> _probe() async {
    setState(() {
      _busy = true;
      _probeRows = const [];
    });
    final state = context.read<AppState>();
    final links = _links.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final rows = <(String, String)>[];
    for (final link in links) {
      final v = Vless.tryParse(link);
      if (v == null) {
        rows.add((link, '解析失败'));
        continue;
      }
      final started = DateTime.now();
      try {
        await state.xray.start(v);
        rows.add(('${v.host}:${v.port}',
            '${DateTime.now().difference(started).inMilliseconds} ms'));
      } catch (e) {
        rows.add(('${v.host}:${v.port}', '失败：$e'));
      }
    }
    await state.xray.stop();
    if (mounted) {
      setState(() {
        _busy = false;
        _probeRows = rows;
      });
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('线路与代理'),
        actions: [
          if (state.xray.running)
            TextButton(onPressed: _stop, child: const Text('停止线路')),
          const SizedBox(width: 6),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Row(
            children: [
              _stat(theme, '状态', state.xray.running ? '已连接' : state.xray.note),
              const SizedBox(width: 10),
              _stat(theme, '端口', state.xray.running ? '${state.xray.port}' : '—'),
              const SizedBox(width: 10),
              _stat(theme, 'proxyip', state.xray.proxyIp.isEmpty ? '链接原样' : state.xray.proxyIp),
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
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                      hintText: 'vless://uuid@host:443?type=xhttp&security=tls&...',
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
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                      hintText: '104.16.0.1:443',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton(
                        onPressed: _busy ? null : _start,
                        child: Text(_busy ? '处理中…' : '启动线路'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: _busy ? null : _probe,
                        child: const Text('测试全部线路'),
                      ),
                      const Spacer(),
                      TextButton(onPressed: _save, child: const Text('保存')),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_probeRows.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                    child: Row(
                      children: [
                        Text('线路测速', style: theme.textTheme.titleSmall),
                        const Spacer(),
                        Text('${_probeRows.length} 条', style: theme.textTheme.labelSmall),
                      ],
                    ),
                  ),
                  for (final (key, value) in _probeRows)
                    ListTile(
                      dense: true,
                      title: Text(key,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                      trailing: Text(value,
                          style: TextStyle(
                            fontSize: 12,
                            color: value.contains('失败')
                                ? theme.colorScheme.error
                                : theme.colorScheme.primary,
                          )),
                    ),
                ],
              ),
            ),
          ],
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
