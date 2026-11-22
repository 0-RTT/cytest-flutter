import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../phosphor_icons.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/paths.dart';
import '../../data/candidates.dart';
import '../../data/history.dart';
import '../../state/app_state.dart';
import '../widgets/glass.dart';
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
  const TestPage({super.key, this.initialInput, this.autoStart = true});

  /// 兼容旧调用：传入 Censys JSON 时直接提取候选，标记「来自抓取结果」。
  final String? initialInput;

  /// 带 [initialInput] 进页时是否立刻开跑。
  ///
  /// 默认 true —— `initialInput` 只由「获取数据 → 导入到本地测试」这条路径传，
  /// 用户点那一下就是「开始」。留成参数是为了让 widget 测试能只验布局、
  /// 不真的去起引擎进程。
  final bool autoStart;

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
      // 从「获取数据」直接带进来时不再要求用户再点一次按钮：进页即开跑。
      if (widget.autoStart && _targets.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _start();
        });
      }
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
    // 选完记录直接开跑：页面上已经没有「开始」按钮，选择本身就是开始。
    if (_targets.isNotEmpty) await _start();
  }

  void _clearTargets() {
    setState(() {
      _targets = const [];
      _sourceLabel = '';
    });
  }

  /// 唯一的测试入口：一键测试 = 指纹筛选 → 延迟 → 速度（引擎 -targets -sha1）。
  ///
  /// 页面上不再有「只延迟 / 只测速 / 一键」三个按钮：用户要的就是完整一遍，
  /// 三个按钮只会制造「点了哪个」的选择成本，也让首屏多出一整行。
  Future<void> _start() async {
    if (_targets.isEmpty) return;
    final state = context.read<AppState>();
    final ok = await state.runLocal(mode: 'both', input: _targets.join('\n'));
    if (!mounted) return;
    if (ok && state.rows.isNotEmpty) {
      await Navigator.of(context).push(
        GlassRoute(builder: (_) => const ResultPage()),
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
      appBar: GlassAppBar(
        title: '本地测试',
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
            // 只留「候选」一块：统计卡片（候选总量 / 当前阶段 / 可用）已移除，
            // 那三项在日志里本来就逐行可见，占着首屏只会挤压日志。
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: _inputCard(theme, state, hasTargets),
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
                        // 进度条并入日志卡片：进度与明细是同一件事的两种表达。
                        progress: pct,
                        progressLabel: state.progressTotal > 0
                            ? '${state.progressCur} / ${state.progressTotal}'
                            : null,
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

  Widget _inputCard(ThemeData theme, AppState state, bool hasTargets) =>
      GlassCard(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(PhosphorIconsRegular.folderOpen,
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
                  // 与输入框同一套语言：细边白底，不再铺灰块。
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant
                          .withValues(alpha: 0.9),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        hasTargets
                            ? PhosphorIconsRegular.fileText
                            : PhosphorIconsRegular.listBullets,
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
                      Icon(PhosphorIconsRegular.caretRight,
                          size: 18, color: theme.colorScheme.onSurfaceVariant),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
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
    try {
      // 与「记录」页同一口径：读盘必须有上限，否则弹层会一直转圈。
      final archives =
          await History.listArchives().timeout(const Duration(seconds: 10));
      final runs =
          await History.listRuns().timeout(const Duration(seconds: 10));
      return (archives, runs);
    } on TimeoutException {
      throw Exception('读取记录超时（10s），存储目录没有响应');
    }
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
          .pop(_PickedRecord(label: info.label, targets: targets));
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
    // 存档要用 label（`AS13335 · 11-20 09:10`）：只显示时间的话，
    // 同一时段抓的几份数据在列表里长得一模一样，根本分不出是哪一份。
    final subtitle = info.isArchive
        ? '${info.label} · ${info.total} 条'
        : '${info.at} · ${info.total} 条 · ${info.usable} 可用';
    return ListTile(
      dense: true,
      enabled: _loadingId == null,
      leading: Icon(
        info.isArchive ? PhosphorIconsRegular.archive : PhosphorIconsRegular.clockCounterClockwise,
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
          : const Icon(PhosphorIconsRegular.caretRight, size: 18),
      onTap: () => _choose(info),
    );
  }
}
