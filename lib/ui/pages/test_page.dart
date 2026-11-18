import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/paths.dart';
import '../../data/candidates.dart';
import '../../data/history.dart';
import '../../state/app_state.dart';
import '../widgets/log_panel.dart';
import 'result_page.dart';

/// 本地测试页：从「本地已有记录」里选候选，跑 Go 引擎的延迟 / 速度测试。
///
/// 输入来源只有两种：
/// 1. 用户点「选择记录」从存档（Censys JSON）或历史结果（result.csv）里挑一条；
/// 2. 由「获取数据」页通过 [initialInput] 直接带入刚抓到的 JSON。
///
/// 不再提供自由粘贴/编辑大段文本的入口 —— 主页面永远只留一行摘要，日志不被挤走。
class TestPage extends StatefulWidget {
  const TestPage({super.key, this.initialInput});

  /// 兼容旧调用：传入 Censys JSON 时直接提取候选，标记「来自抓取结果」。
  final String? initialInput;

  @override
  State<TestPage> createState() => _TestPageState();
}

class _TestPageState extends State<TestPage> {
  /// 当前选中的候选（`ip:port`，已去重保序）。
  List<String> _targets = const [];

  /// 来源标签：记录时间，或「来自抓取结果」。
  String _sourceLabel = '';

  final _logScroll = ScrollController();

  /// 用户手动上滑看历史时不再强行拉回底部。
  bool _stickToBottom = true;

  @override
  void initState() {
    super.initState();
    final raw = widget.initialInput;
    if (raw != null && raw.trim().isNotEmpty) {
      _targets = extractTargets(raw);
      _sourceLabel = '来自抓取结果';
    }
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
    _logScroll.dispose();
    super.dispose();
  }

  String get _summaryLabel {
    if (_targets.isEmpty) return '选择记录';
    final source = _sourceLabel.isEmpty ? '' : '$_sourceLabel · ';
    return '已选：$source${_targets.length} 个候选';
  }

  Future<void> _pickRecord() async {
    final picked = await showModalBottomSheet<_PickedRecord>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _RecordPickerSheet(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _targets = picked.targets;
      _sourceLabel = picked.label;
    });
  }

  void _clearTargets() {
    setState(() {
      _targets = const [];
      _sourceLabel = '';
    });
  }

  Future<void> _start(String mode) async {
    if (_targets.isEmpty) return;
    final state = context.read<AppState>();
    final ok = await state.runLocal(mode: mode, input: _targets.join('\n'));
    if (!mounted) return;
    if (ok && state.rows.isNotEmpty) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ResultPage()),
      );
    }
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
    final hasTargets = _targets.isNotEmpty;

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
                          : (hasTargets ? '${_targets.length}' : '—')),
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
              child: _inputCard(theme, state, hasTargets),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: _progressCard(theme, state, pct),
            ),
            const SizedBox(height: 10),
            // 日志模块：吃掉剩余空间、独立滚动，永远在首屏。
            // fromLTRB 的 bottom=14 是「包底」：让卡片底边和圆角完整露出来。
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

  Widget _inputCard(ThemeData theme, AppState state, bool hasTargets) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.folder_open_outlined,
                      size: 17, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text('候选', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  if (hasTargets)
                    TextButton(
                      onPressed: state.running ? null : _clearTargets,
                      child: const Text('清空'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              InkWell(
                onTap: state.running ? null : _pickRecord,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 52),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        hasTargets
                            ? Icons.description_outlined
                            : Icons.list_alt_outlined,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _summaryLabel,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: hasTargets
                                ? null
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Icon(Icons.chevron_right,
                          size: 18, color: theme.colorScheme.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // 三个动作按钮取代旧的「模式切换 + 开始测试」：
              // 用户点哪个就跑哪个，语义自解释，省掉一次二次选择。
              // 窄屏下 3 个按钮并排仍需放得下，所以不带图标、用紧凑内边距。
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: state.running || !hasTargets
                          ? null
                          : () => _start('latency'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('延迟测试'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: state.running || !hasTargets
                          ? null
                          : () => _start('speed'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('速度测试'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: state.running || !hasTargets
                          ? null
                          : () => _start('both'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text(state.running ? '运行中…' : '一键测试'),
                    ),
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

/// 记录选择结果。
class _PickedRecord {
  const _PickedRecord({required this.label, required this.targets});

  /// 展示用来源标签（记录时间）。
  final String label;

  /// 提取出的 `ip:port` 候选。
  final List<String> targets;
}

/// 记录选择弹层：上半区 Censys 存档，下半区历史测试结果。
///
/// 两类记录共用 [RecordInfo]，靠 [RecordInfo.isArchive] 区分读取方式：
/// - 存档是 JSON 文件；
/// - 历史结果要读目录内的 `result.csv` 原文（再交给 [extractTargets]）。
class _RecordPickerSheet extends StatefulWidget {
  const _RecordPickerSheet();

  @override
  State<_RecordPickerSheet> createState() => _RecordPickerSheetState();
}

class _RecordPickerSheetState extends State<_RecordPickerSheet> {
  late final Future<(List<RecordInfo>, List<RecordInfo>)> _records = _load();

  /// 正在读取的记录 id（禁用重复点击 + 显示进度）。
  String? _loadingId;

  static Future<(List<RecordInfo>, List<RecordInfo>)> _load() async {
    final archives = await History.listArchives();
    final runs = await History.listRuns();
    return (archives, runs);
  }

  Future<String> _readRunContent(String id) async {
    final dir = await Paths.runs();
    final file = File('${dir.path}/$id/result.csv');
    if (!await file.exists()) throw Exception('记录缺少 result.csv');
    return file.readAsString();
  }

  Future<void> _choose(RecordInfo info) async {
    if (_loadingId != null) return;
    setState(() => _loadingId = info.id);
    try {
      final content = info.isArchive
          ? await History.readArchive(info.id)
          : await _readRunContent(info.id);
      final targets = extractTargets(content);
      if (!mounted) return;
      if (targets.isEmpty) {
        setState(() => _loadingId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('这条记录里没有可用的 ip:port 候选')),
        );
        return;
      }
      Navigator.of(context)
          .pop(_PickedRecord(label: info.at, targets: targets));
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('读取失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: FutureBuilder<(List<RecordInfo>, List<RecordInfo>)>(
        future: _records,
        builder: (context, snapshot) {
          final Widget body;
          if (snapshot.connectionState != ConnectionState.done) {
            body = const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            body = Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('读取记录失败：${snapshot.error}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.error)),
              ),
            );
          } else {
            final (archives, runs) = snapshot.data!;
            if (archives.isEmpty && runs.isEmpty) {
              body = Center(
                child: Text('还没有记录，先去「获取数据」抓一次',
                    style: TextStyle(color: theme.hintColor)),
              );
            } else {
              body = ListView(
                padding: const EdgeInsets.only(bottom: 14),
                children: [
                  _sectionHeader(theme, 'Censys 存档（${archives.length}）'),
                  if (archives.isEmpty)
                    _emptyHint(theme, '没有存档')
                  else
                    for (final info in archives) _tile(theme, info),
                  const Divider(height: 20),
                  _sectionHeader(theme, '历史测试结果（${runs.length}）'),
                  if (runs.isEmpty)
                    _emptyHint(theme, '没有历史结果')
                  else
                    for (final info in runs) _tile(theme, info),
                ],
              );
            }
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
                child: Row(
                  children: [
                    Text('选择记录', style: theme.textTheme.titleMedium),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                  ],
                ),
              ),
              Expanded(child: body),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionHeader(ThemeData theme, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(title,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.primary)),
      );

  Widget _emptyHint(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Text(text,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.hintColor)),
      );

  Widget _tile(ThemeData theme, RecordInfo info) {
    final loading = _loadingId == info.id;
    final subtitle = info.isArchive
        ? '${info.at} · ${info.total} 条'
        : '${info.at} · ${info.total} 条 · ${info.usable} 可用';
    return ListTile(
      dense: true,
      enabled: _loadingId == null,
      leading: Icon(
        info.isArchive ? Icons.archive_outlined : Icons.history,
        size: 20,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(subtitle,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: loading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.chevron_right, size: 18),
      onTap: () => _choose(info),
    );
  }
}
