import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import 'vless_test_page.dart';

class ResultPage extends StatefulWidget {
  const ResultPage({super.key});

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage> {
  /// 勾选的行索引；默认全选可用节点，保持旧版「一键用全部」的行为。
  final Set<int> _selected = <int>{};

  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final rows = context.read<AppState>().rows;
    for (var i = 0; i < rows.length; i++) {
      if ((rows[i]['Reason'] ?? '').isEmpty) _selected.add(i);
    }
  }

  List<String> _targets(AppState state) {
    final out = <String>[];
    for (final i in _selected.toList()..sort()) {
      if (i < 0 || i >= state.rows.length) continue;
      final r = state.rows[i];
      if ((r['Reason'] ?? '').isNotEmpty) continue;
      final ip = r['IP'] ?? '';
      final port = r['Port'] ?? '';
      if (ip.isNotEmpty && port.isNotEmpty) out.add('$ip:$port');
    }
    return out;
  }

  /// 进入 VLESS 测试页：本地测速只证明 IP:port 通，真正能不能用要跑协议测速。
  /// 推送入口挪到测试页里 —— 只有测速成功的节点才有资格被推送。
  void _openTest() {
    final state = context.read<AppState>();
    final targets = _targets(state);
    if (targets.isEmpty) {
      _toast(context, '先勾选至少一个测速成功的节点');
      return;
    }
    final template = state.settings.vlessLinks.isNotEmpty
        ? state.settings.vlessLinks.first
        : '';
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VlessTestPage(
          targets: targets,
          template: template,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    if (state.rows.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('结果')),
        // 底部 SafeArea：Scaffold 的 body 不避让系统手势条 / 三键导航。
        body: SafeArea(
          top: false,
          child: Center(
            child: Text('还没有结果，先跑一次本地测试',
                style: TextStyle(color: theme.hintColor)),
          ),
        ),
      );
    }

    final picked = _targets(state).length;

    return Scaffold(
      appBar: AppBar(
        title: Text('结果 · ${state.rows.length} 条'),
        actions: [
          TextButton.icon(
            onPressed: picked == 0 ? null : _openTest,
            icon: const Icon(Icons.science_outlined, size: 17),
            label: Text('测试 ($picked)'),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => _onAction(context, v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'csv', child: Text('导出 CSV（复制）')),
            ],
          ),
        ],
      ),
      // 底部 SafeArea：Scaffold 的 body 不避让系统手势条 / 三键导航。
      // top: false —— 顶部已由 AppBar 处理。
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  _stat(theme, '可用', '${state.usableCount}'),
                  const SizedBox(width: 10),
                  _stat(theme, '最快',
                      '${state.fastestSpeed.toStringAsFixed(2)} MiB/s'),
                  const SizedBox(width: 10),
                  _stat(theme, '均延迟', '${state.averageLatency} ms'),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Row(
                children: [
                  Text('勾选要推送的节点',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() {
                      if (_selected.length == state.usableCount) {
                        _selected.clear();
                      } else {
                        for (var i = 0; i < state.rows.length; i++) {
                          if ((state.rows[i]['Reason'] ?? '').isEmpty) {
                            _selected.add(i);
                          }
                        }
                      }
                    }),
                    child: Text(_selected.length == state.usableCount
                        ? '取消全选'
                        : '全选可用'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.separated(
                // 底部 24 是纯视觉呼吸：系统手势条已由外层 SafeArea 避让。
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: state.rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final r = state.rows[i];
                  final ok = (r['Reason'] ?? '').isEmpty;
                  final speed = double.tryParse(r['Speed (MiB/s)'] ?? '') ?? 0;
                  return ListTile(
                    dense: true,
                    onTap: ok
                        ? () => setState(() {
                              if (_selected.contains(i)) {
                                _selected.remove(i);
                              } else {
                                _selected.add(i);
                              }
                            })
                        : null,
                    leading: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Checkbox 只作选中指示：整行点击统一由 ListTile.onTap
                        // 处理，否则 checkbox 与行会各切一次、等于没变。
                        IgnorePointer(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: Checkbox(
                              value: _selected.contains(i),
                              onChanged: ok ? (_) {} : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        Text('${i + 1}',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: theme.hintColor)),
                      ],
                    ),
                    // 长地址 / 长 Reason 会顶破 ListTile，单行省略。
                    title: Text(
                      '${r['IP']}:${r['Port']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        // monospace 不含中文字形，缺 fallback 时含中文的行会显示方块
                        fontFamilyFallback: const ['sans-serif'],
                        fontSize: 13,
                        color: ok ? null : theme.hintColor,
                      ),
                    ),
                    subtitle: ok
                        ? Text('${r['Latency (ms)']} ms',
                            style:
                                TextStyle(fontSize: 11, color: theme.hintColor))
                        : Text(
                            r['Reason'] ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                TextStyle(fontSize: 11, color: theme.hintColor),
                          ),
                    trailing: ok
                        ? Text(
                            speed > 0
                                ? '${speed.toStringAsFixed(2)} MiB/s'
                                : '—',
                            style: TextStyle(
                                color: theme.colorScheme.primary, fontSize: 12),
                          )
                        : const SizedBox.shrink(),
                  );
                },
              ),
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
                Text(value, style: theme.textTheme.titleSmall),
              ],
            ),
          ),
        ),
      );

  Future<void> _onAction(BuildContext context, String action) async {
    if (action != 'csv') return;
    final state = context.read<AppState>();
    final buf = StringBuffer('IP,Port,Latency (ms),Speed (MiB/s),Reason\n');
    for (final r in state.rows) {
      buf.writeln(
          '${r['IP']},${r['Port']},${r['Latency (ms)']},${r['Speed (MiB/s)']},${r['Reason']}');
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    _toast(context, 'CSV 已复制到剪贴板');
  }

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }
}
