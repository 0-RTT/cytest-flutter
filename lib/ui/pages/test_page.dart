import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';

class TestPage extends StatefulWidget {
  const TestPage({super.key, this.initialInput});

  final String? initialInput;

  @override
  State<TestPage> createState() => _TestPageState();
}

class _TestPageState extends State<TestPage> {
  late final TextEditingController _input =
      TextEditingController(text: widget.initialInput ?? '');
  String _mode = 'full';
  final _logScroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final state = context.read<AppState>();
    final ok = await state.runLocal(mode: _mode, input: _input.text);
    if (!mounted) return;
    if (ok && state.rows.isNotEmpty) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const _QuickResult()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    // 日志自动滚到底
    if (state.logs.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients) {
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        }
      });
    }

    final pct = state.progressTotal > 0
        ? (state.progressCur / state.progressTotal).clamp(0.0, 1.0)
        : 0.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('本地测试'),
        actions: [
          if (state.running)
            TextButton(
              onPressed: () => state.cancel(),
              child: Text('取消', style: TextStyle(color: theme.colorScheme.error)),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(14),
              children: [
                Row(
                  children: [
                    _stat(theme, '候选总量', state.progressTotal > 0 ? '${state.progressTotal}' : '—'),
                    const SizedBox(width: 10),
                    _stat(theme, '当前阶段', state.progressStage.isEmpty ? '待开始' : _trim(state.progressStage)),
                    const SizedBox(width: 10),
                    _stat(theme, '可用', state.rows.isEmpty ? '—' : '${state.usableCount}'),
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
                        Row(
                          children: [
                            Text('输入', style: theme.textTheme.titleSmall),
                            const Spacer(),
                            SegmentedButton<String>(
                              segments: const [
                                ButtonSegment(value: 'full', label: Text('完整三阶段')),
                                ButtonSegment(value: 'speed', label: Text('只测速')),
                              ],
                              selected: {_mode},
                              onSelectionChanged: (s) =>
                                  setState(() => _mode = s.first),
                              showSelectedIcon: false,
                              style: const ButtonStyle(visualDensity: VisualDensity.compact),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _input,
                          maxLines: 6,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                          decoration: InputDecoration(
                            border: const OutlineInputBorder(),
                            isDense: true,
                            hintText: _mode == 'full'
                                ? '粘贴 Censys JSON（可从「获取数据」导入）'
                                : '每行一个 ip:port',
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            FilledButton.icon(
                              onPressed: state.running ? null : _start,
                              icon: const Icon(Icons.play_arrow, size: 18),
                              label: Text(state.running ? '运行中…' : '开始测试'),
                            ),
                            const Spacer(),
                            TextButton(
                              onPressed: () => setState(() => _input.clear()),
                              child: const Text('清空'),
                            ),
                          ],
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
                            Text('进度', style: theme.textTheme.titleSmall),
                            const Spacer(),
                            Text(
                              state.progressTotal > 0
                                  ? '${state.progressCur} / ${state.progressTotal}'
                                  : '等待开始',
                              style: theme.textTheme.labelSmall,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: pct,
                            minHeight: 5,
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
                            Text('日志', style: theme.textTheme.titleSmall),
                            const Spacer(),
                            if (state.logs.isNotEmpty)
                              Text('${state.logs.length} 行',
                                  style: theme.textTheme.labelSmall),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Container(
                          height: 240,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: state.logs.isEmpty
                              ? Center(
                                  child: Text('暂无输出',
                                      style: theme.textTheme.bodySmall?.copyWith(
                                          color: theme.colorScheme.onSurfaceVariant)),
                                )
                              : ListView.builder(
                                  controller: _logScroll,
                                  padding: const EdgeInsets.all(10),
                                  itemCount: state.logs.length,
                                  itemBuilder: (_, i) {
                                    final line = state.logs[i];
                                    return Text(
                                      line,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 11.5,
                                        color: line.contains('✗') || line.contains('失败')
                                            ? theme.colorScheme.error
                                            : line.contains('阶段')
                                                ? theme.colorScheme.primary
                                                : null,
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (state.lastError != null) ...[
                  const SizedBox(height: 12),
                  Text(state.lastError!,
                      style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _trim(String s) {
    final t = s.replaceAll(RegExp(r'^[=\-\s]+|[=\-\s]+$'), '');
    return t.length > 10 ? t.substring(0, 10) : t;
  }

  Widget _stat(ThemeData theme, String label, String value) => Expanded(
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelSmall),
                const SizedBox(height: 2),
                Text(value, style: theme.textTheme.titleMedium),
              ],
            ),
          ),
        ),
      );
}

/// 测试完成后就地展示结果，避免再跳一次。
class _QuickResult extends StatelessWidget {
  const _QuickResult();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    if (state.rows.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('结果')),
        body: const Center(child: Text('还没有结果')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text('结果 · ${state.rows.length} 条')),
      body: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: state.rows.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final r = state.rows[i];
          final ok = (r['Reason'] ?? '').isEmpty;
          return ListTile(
            dense: true,
            leading: Text('${i + 1}', style: theme.textTheme.labelSmall),
            title: Text('${r['IP']}:${r['Port']}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
            subtitle: ok
                ? null
                : Text(r['Reason'] ?? '',
                    style: TextStyle(color: theme.hintColor, fontSize: 11)),
            trailing: ok
                ? Text(
                    '${(double.tryParse(r['Speed (MiB/s)'] ?? '') ?? 0).toStringAsFixed(2)} MiB/s',
                    style: TextStyle(color: theme.colorScheme.primary, fontSize: 12),
                  )
                : Text('${r['Latency (ms)']} ms',
                    style: TextStyle(color: theme.hintColor, fontSize: 12)),
          );
        },
      ),
    );
  }
}
