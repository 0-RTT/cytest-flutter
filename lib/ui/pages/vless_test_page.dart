import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/link_result_sort.dart';
import '../../data/link_test.dart';
import '../../data/node_template.dart';
import '../../state/app_state.dart';
import '../widgets/log_panel.dart';
import 'publish_page.dart';

/// VLESS 测试页：把结果页选中的 `ip:port` × 模板展开成 vless 链接，
/// 跑一遍链路测速（先延迟后速度），再把勾选的节点送进推送页。
///
/// 与「本地测试」的区别：本地测试走 Go 引擎测裸 IP 的 TCP 连通性/下载速度；
/// 这里是真起 Xray 用 VLESS 协议测端到端，结果才代表「这条线路能不能用」。
class VlessTestPage extends StatefulWidget {
  const VlessTestPage({
    super.key,
    required this.targets,
    required this.template,
  });

  /// 从结果页带过来的 `ip:port` 列表。
  final List<String> targets;

  /// vless 模板链接（含 host:port 槽位）。
  final String template;

  @override
  State<VlessTestPage> createState() => _VlessTestPageState();
}

class _VlessTestPageState extends State<VlessTestPage> {
  /// 当前排序维度：默认按延迟（先看谁连得上，再看速度）。
  LinkResultSort _sort = LinkResultSort.latency;

  /// 选中项按 `host:port` 记录：排序会改变下标，用 key 才不会串行。
  final Set<String> _selectedKeys = <String>{};

  /// 是否已按「测速成功」做过一次默认全选（进入页面 / 每轮测速结束后）。
  bool _selectionReady = false;

  final _logScroll = ScrollController();
  bool _stickToBottom = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_selectionReady) return;
    final results = context.read<AppState>().linkResults;
    if (results.isEmpty) return;
    _selectionReady = true;
    _applyDefaultSelection(results);
  }

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  bool get _templateMissing => widget.template.trim().isEmpty;
  bool get _targetsMissing => widget.targets.isEmpty;
  bool get _invalid => _templateMissing || _targetsMissing;

  void _applyDefaultSelection(List<LinkTestResult> results) {
    _selectedKeys
      ..clear()
      ..addAll(results
          .where((r) => r.hasSpeed && _selectable(r))
          .map((r) => r.key));
  }

  Future<void> _run() async {
    if (_invalid) return;
    final links = expandTemplate(widget.template, widget.targets);
    if (links.isEmpty) {
      _toast('模板里没有可展开的节点，检查模板是否含 host:port');
      return;
    }
    final state = context.read<AppState>();
    setState(() => _selectionReady = false);
    final ok = await state.runLinkTest(links, mode: LinkTestMode.auto);
    if (!mounted) return;
    setState(() {
      _applyDefaultSelection(state.linkResults);
      _selectionReady = true;
    });
    if (!ok) {
      final error = state.linkTestError;
      if (error != null && error.isNotEmpty) _toast(error);
    }
  }

  /// 可勾选的条目：探测完成且成功（没有 error、非取消态），host/port 可解析。
  /// pending/running 也排除：还没测完的节点不该进推送。
  bool _selectable(LinkTestResult r) =>
      r.ok && r.state == ProbeState.done && r.host.isNotEmpty && r.port > 0;

  List<String> _selectedTargets(List<LinkTestResult> results) {
    final out = <String>[];
    for (final r in results) {
      if (!_selectedKeys.contains(r.key)) continue;
      if (!_selectable(r)) continue;
      out.add('${r.host}:${r.port}');
    }
    return out;
  }

  void _toggle(String key) {
    setState(() {
      if (!_selectedKeys.remove(key)) _selectedKeys.add(key);
    });
  }

  void _toggleAll(List<LinkTestResult> results) {
    final selectable = results.where(_selectable).map((r) => r.key).toList();
    final allSelected = selectable.isNotEmpty &&
        selectable.every(_selectedKeys.contains);
    setState(() {
      if (allSelected) {
        _selectedKeys.clear();
      } else {
        _selectedKeys
          ..clear()
          ..addAll(selectable);
      }
    });
  }

  void _push(List<LinkTestResult> results) {
    final targets = _selectedTargets(results);
    if (targets.isEmpty) {
      _toast('先勾选至少一个测速成功的节点');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PublishPage(
          targets: targets,
          template: widget.template,
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
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
    if (mounted) _toast('日志已复制');
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final running = state.linkTestRunning;

    _autoScrollLogs();

    final sorted = sortLinkResults(state.linkResults, sort: _sort);
    final selectedCount = _selectedTargets(state.linkResults).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('测试'),
        actions: [
          if (running)
            TextButton(
              onPressed: state.cancelLinkTest,
              child:
                  Text('取消', style: TextStyle(color: theme.colorScheme.error)),
            ),
        ],
      ),
      // 底部 SafeArea：body 不自动避让系统手势条 / 三键导航；top 由 AppBar 处理。
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: _headerCard(theme, state, running),
            ),
            if (_invalid)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
                child: Text(
                  _targetsMissing
                      ? '目标列表为空：返回结果页重新勾选节点后再进入'
                      : '没有可用的 vless 模板：先在「线路与代理」或设置里填一条',
                  style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
              child: _toolbar(theme, state, sorted, running),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                child: _resultList(theme, sorted, running),
              ),
            ),
            SizedBox(
              height: 170,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: LogPanel(
                  key: const ValueKey('vless_test_log_card'),
                  title: '测速日志',
                  lines: state.logs,
                  running: running,
                  emptyText: '尚未开始测试',
                  scrollController: _logScroll,
                  onJumpToLatest: _jumpToLatest,
                  onCopy: _copyLogs,
                ),
              ),
            ),
            if (state.linkTestError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: Text(state.linkTestError!,
                    style:
                        TextStyle(color: theme.colorScheme.error, fontSize: 12)),
              ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
          child: FilledButton.icon(
            key: const ValueKey('vless_test_push'),
            onPressed: running || _invalid || selectedCount == 0
                ? null
                : () => _push(state.linkResults),
            icon: const Icon(Icons.send_outlined, size: 18),
            label: Text('推送 ($selectedCount)'),
          ),
        ),
      ),
    );
  }

  Widget _headerCard(ThemeData theme, AppState state, bool running) {
    final done = state.linkResults
        .where((r) =>
            r.state == ProbeState.done ||
            r.state == ProbeState.failed ||
            r.state == ProbeState.cancelled)
        .length;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.science_outlined,
                    size: 17, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text('VLESS 测试', style: theme.textTheme.titleSmall),
                const Spacer(),
                Text('${widget.targets.length} 个目标',
                    style: theme.textTheme.labelSmall),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _templateMissing
                  ? '未配置模板'
                  : '模板已就绪 · ${widget.template.length} 字符',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: running || _invalid ? null : _run,
                  icon: Icon(
                    state.linkResults.isEmpty
                        ? Icons.play_arrow
                        : Icons.refresh,
                    size: 18,
                  ),
                  label: Text(
                    running
                        ? '测速中…'
                        : (state.linkResults.isEmpty ? '开始测试' : '重新测试'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    state.linkStage.isEmpty
                        ? '待开始'
                        : '${state.linkStage} · $done/${state.linkResults.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(
    ThemeData theme,
    AppState state,
    List<LinkTestResult> sorted,
    bool running,
  ) {
    final selectable =
        sorted.where(_selectable).map((r) => r.key).toList(growable: false);
    final allSelected =
        selectable.isNotEmpty && selectable.every(_selectedKeys.contains);
    return Row(
      children: [
        SegmentedButton<LinkResultSort>(
          segments: [
            for (final sort in LinkResultSort.values)
              ButtonSegment(value: sort, label: Text(sort.label)),
          ],
          selected: <LinkResultSort>{_sort},
          // 测速进行中禁止切换排序：正在刷新的行会跳来跳去。
          onSelectionChanged: running
              ? null
              : (s) => setState(() => _sort = s.first),
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
        ),
        const Spacer(),
        TextButton(
          onPressed: running || selectable.isEmpty
              ? null
              : () => _toggleAll(sorted),
          child: Text(allSelected ? '取消全选' : '全选'),
        ),
      ],
    );
  }

  Widget _resultList(
    ThemeData theme,
    List<LinkTestResult> sorted,
    bool running,
  ) {
    if (sorted.isEmpty) {
      return Center(
        child: Text('还没有结果，点「开始测试」跑一轮',
            style: TextStyle(color: theme.hintColor)),
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListView.separated(
        // 底部 12 让最后一行远离卡片圆角，不再像被切掉。
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: sorted.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final r = sorted[i];
          final canSelect = _selectable(r);
          final selected = _selectedKeys.contains(r.key);
          return ListTile(
            dense: true,
            onTap: running || !canSelect ? null : () => _toggle(r.key),
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IgnorePointer(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: Checkbox(
                      value: selected,
                      onChanged: canSelect ? (_) {} : null,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Text('${i + 1}',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.hintColor)),
              ],
            ),
            title: Text(
              r.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontFamilyFallback: const ['sans-serif'],
                color: canSelect ? null : theme.hintColor,
              ),
            ),
            subtitle: Text(
              r.error == null
                  ? '${r.host}:${r.port}'
                  : '${r.host}:${r.port} · ${r.error}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                fontFamilyFallback: const ['sans-serif'],
                color: r.error != null
                    ? theme.colorScheme.error
                    : theme.hintColor,
              ),
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _speedText(r),
                  style: TextStyle(
                    fontSize: 12,
                    color: r.hasSpeed
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  r.latencyKnown ? '${r.latencyMs} ms' : '—',
                  style: TextStyle(fontSize: 11, color: theme.hintColor),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 速度列文案：未测绝不显示 0.00。
  String _speedText(LinkTestResult r) {
    if (r.state == ProbeState.cancelled) return '已取消';
    if (r.error != null) return '失败';
    if (!r.hasSpeed) return '未测';
    return '${(r.speedMib ?? 0).toStringAsFixed(2)} MiB/s';
  }
}
