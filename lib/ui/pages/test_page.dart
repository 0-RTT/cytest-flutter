import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../widgets/log_panel.dart';

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

  /// 输入摘要（候选数 + 体积），避免在主页面铺开整段 JSON。
  String _summary = '';

  /// 用户手动上滑看历史时不再强行拉回底部。
  bool _stickToBottom = true;

  @override
  void initState() {
    super.initState();
    _updateSummary();
    _logScroll.addListener(() {
      if (!_logScroll.hasClients) return;
      final after = _logScroll.position.extentAfter;
      if (after > 120 && _stickToBottom) {
        _stickToBottom = false;
      } else if (after <= 8 && !_stickToBottom) {
        _stickToBottom = true;
      }
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  /// 摘要只做一次轻量解析，不随 build 反复 jsonDecode 大字符串。
  void _updateSummary() {
    final t = _input.text.trim();
    if (t.isEmpty) {
      _summary = '';
      return;
    }
    var count = 0;
    try {
      final decoded = jsonDecode(t);
      final results = decoded is Map ? decoded['results'] : null;
      final hits = results is Map ? results['hits'] : null;
      if (hits is List) count = hits.length;
    } catch (_) {
      // 只测速模式传的是 ip:port 文本， Decode 失败属正常。
    }
    if (count == 0) {
      count = t.split('\n').where((l) => l.trim().isNotEmpty).length;
    }
    _summary = '$count 个候选 · ${_formatBytes(t.length)}';
  }

  static String _formatBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
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

  /// 全文编辑放进底部弹层：主页面永远只留一行摘要，日志不被挤出去。
  void _openEditor(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _InputEditorSheet(
        initial: _input.text,
        mode: _mode,
        onSave: (text) {
          _input.text = text;
          _updateSummary();
          setState(() {});
        },
      ),
    );
  }

  void _autoScrollLogs() {
    if (!_stickToBottom || !_logScroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  void _jumpToLatest() {
    setState(() => _stickToBottom = true);
    if (_logScroll.hasClients) {
      _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    }
  }

  Future<void> _copyLogs() async {
    final state = context.read<AppState>();
    await Clipboard.setData(ClipboardData(text: state.logs.join('\n')));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('日志已复制')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final hasInput = _input.text.trim().isNotEmpty;

    _autoScrollLogs();

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
              child:
                  Text('取消', style: TextStyle(color: theme.colorScheme.error)),
            ),
        ],
      ),
      // 底部 SafeArea：Scaffold 的 body 不会自动避让系统手势条 / 三键导航，
      // 不包这层，最后的错误提示会被系统栏压住。
      // top: false —— 顶部已由 AppBar 处理。
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部三卡固定，不参与滚动。
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: Row(
                children: [
                  _stat(
                      theme,
                      '候选总量',
                      state.progressTotal > 0
                          ? '${state.progressTotal}'
                          : '—'),
                  const SizedBox(width: 10),
                  _stat(
                      theme,
                      '当前阶段',
                      state.progressStage.isEmpty
                          ? '待开始'
                          : _trim(state.progressStage)),
                  const SizedBox(width: 10),
                  _stat(theme, '可用',
                      state.rows.isEmpty ? '—' : '${state.usableCount}'),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: _inputCard(theme, state, hasInput),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: _progressCard(theme, state, pct),
            ),
            const SizedBox(height: 10),
            // 日志模块：吃掉剩余空间、独立滚动，永远在首屏。
            // fromLTRB 的 bottom=14 是「包底」：让卡片底边和圆角完整露出来，
            // 否则贴着屏幕边缘会融合在一起、最后一行看着像被切掉。
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: LogPanel(
                        key: const ValueKey('test_page_log_card'),
                        title: '日志',
                        lines: state.logs,
                        running: state.running,
                        scrollController: _logScroll,
                        onJumpToLatest: _jumpToLatest,
                        onCopy: _copyLogs,
                      ),
                    ),
                    if (state.lastError != null) ...[
                      const SizedBox(height: 8),
                      Text(state.lastError!,
                          style: TextStyle(
                              color: theme.colorScheme.error, fontSize: 12)),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inputCard(ThemeData theme, AppState state, bool hasInput) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.input_outlined,
                      size: 17, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text('输入', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'full', label: Text('完整三阶段')),
                      ButtonSegment(value: 'speed', label: Text('只测速')),
                    ],
                    selected: {_mode},
                    onSelectionChanged: state.running
                        ? null
                        : (s) => setState(() => _mode = s.first),
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                        visualDensity: VisualDensity.compact),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              InkWell(
                onTap: state.running ? null : () => _openEditor(context),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 52),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        hasInput
                            ? Icons.description_outlined
                            : Icons.content_paste_outlined,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: hasInput
                            ? Text(_summary,
                                style: theme.textTheme.bodyMedium)
                            : Text('点击粘贴候选数据',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant)),
                      ),
                      Icon(Icons.edit_outlined,
                          size: 17,
                          color: theme.colorScheme.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: state.running || !hasInput ? null : _start,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: Text(state.running ? '运行中…' : '开始测试'),
                  ),
                  const Spacer(),
                  if (hasInput)
                    TextButton(
                      onPressed: state.running
                          ? null
                          : () => setState(() {
                                _input.clear();
                                _updateSummary();
                              }),
                      child: const Text('清空'),
                    ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _progressCard(ThemeData theme, AppState state, double pct) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
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
                child: LinearProgressIndicator(value: pct, minHeight: 5),
              ),
            ],
          ),
        ),
      );

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


/// 编辑弹层自己持有 controller：showModalBottomSheet 的 Future 在退出动画
/// 开始前就 complete，若在那时 dispose，正在卸载的 TextField 仍会访问它。
class _InputEditorSheet extends StatefulWidget {
  const _InputEditorSheet({
    required this.initial,
    required this.mode,
    required this.onSave,
  });

  final String initial;
  final String mode;
  final ValueChanged<String> onSave;

  @override
  State<_InputEditorSheet> createState() => _InputEditorSheetState();
}

class _InputEditorSheetState extends State<_InputEditorSheet> {
  late final TextEditingController _draft =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.65,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('编辑候选数据', style: theme.textTheme.titleMedium),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: TextField(
                controller: _draft,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  // Android 的 monospace 族不含完整中文字形，缺 fallback 会显示方块
                  fontFamilyFallback: ['sans-serif'],
                  fontSize: 12,
                ),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  isDense: true,
                  hintText: widget.mode == 'full'
                      ? '粘贴 Censys JSON（可从「获取数据」导入）'
                      : '每行一个 ip:port',
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                widget.onSave(_draft.text);
                Navigator.of(context).pop();
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
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
        // 底部 SafeArea：Scaffold 的 body 不避让系统手势条 / 三键导航。
        body: const SafeArea(
          top: false,
          child: Center(child: Text('还没有结果')),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text('结果 · ${state.rows.length} 条')),
      body: SafeArea(
        top: false,
        child: ListView.separated(
          // 底部 24 是纯视觉呼吸：系统手势条已由外层 SafeArea 避让。
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          itemCount: state.rows.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final r = state.rows[i];
            final ok = (r['Reason'] ?? '').isEmpty;
            return ListTile(
              dense: true,
              leading: Text('${i + 1}', style: theme.textTheme.labelSmall),
              // 长地址/长 Reason 会顶破 ListTile，单行省略；完整内容在「结果」页看。
              title: Text(
                '${r['IP']}:${r['Port']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontFamilyFallback: ['sans-serif'],
                  fontSize: 13,
                ),
              ),
              subtitle: ok
                  ? null
                  : Text(
                      r['Reason'] ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: theme.hintColor, fontSize: 11),
                    ),
              trailing: ok
                  ? Text(
                      '${(double.tryParse(r['Speed (MiB/s)'] ?? '') ?? 0).toStringAsFixed(2)} MiB/s',
                      style: TextStyle(
                          color: theme.colorScheme.primary, fontSize: 12),
                    )
                  : Text('${r['Latency (ms)']} ms',
                      style: TextStyle(color: theme.hintColor, fontSize: 12)),
            );
          },
        ),
      ),
    );
  }
}
