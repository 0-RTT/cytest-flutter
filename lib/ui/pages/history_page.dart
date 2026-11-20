import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/history.dart';
import '../../data/link_test.dart';
import '../../data/link_test_store.dart';
import '../../state/app_state.dart';
import '../widgets/glass.dart';
import 'result_page.dart';
import 'test_page.dart';
import 'vless_test_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

/// 一条可被选中的记录。三种来源的 id 可能撞车（三阶段是时间戳目录、
/// 链路测速是时间戳文件名），所以选中集合里必须带种类前缀。
enum _Kind { run, archive, link }

class _Pick {
  const _Pick(this.kind, this.id);
  final _Kind kind;
  final String id;

  String get key => '${kind.name}:$id';

  @override
  bool operator ==(Object other) => other is _Pick && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

class _HistoryPageState extends State<HistoryPage> {
  List<RecordInfo> _runs = const [];
  List<RecordInfo> _archives = const [];

  /// 链路测速（VLESS）历史。落盘在 `cytest/linktest/`，与三阶段的 `runs/` 分开。
  List<LinkTestRun> _linkRuns = const [];

  bool _loading = true;

  /// 多选状态。`_selecting` 时每行前面出现勾选框，底部出现删除条。
  bool _selecting = false;
  final Set<_Pick> _selected = <_Pick>{};

  /// 加载失败原因。**必须存在**：没有它，读盘异常会让 `_loading` 永远停在 true，
  /// 页面就一直转圈（用户无法区分「还在读」和「已经崩了」）。
  String? _error;

  /// 读盘超时上限：调用卡住（插件通道无响应 / 目录不可访问）时也要有终态。
  static const _loadTimeout = Duration(seconds: 10);

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final runs = await History.listRuns().timeout(_loadTimeout);
      final archives = await History.listArchives().timeout(_loadTimeout);
      final linkRuns = await LinkTestStore().list().timeout(_loadTimeout);
      if (!mounted) return;
      setState(() {
        _runs = runs;
        _archives = archives;
        _linkRuns = linkRuns;
        // 刷新后清空选中：已删掉的条目不能留在选中集合里（否则底部会显示
        // 「已选 3 项」但列表里一条勾都没有）。
        _selected.clear();
        _selecting = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _error = '读取记录超时（${_loadTimeout.inSeconds}s）：'
          '存储目录没有响应。点「重试」再试一次；仍然失败请检查应用存储权限。');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '读取记录失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      if (!_selecting) _selected.clear();
    });
  }

  void _togglePick(_Pick pick) {
    setState(() {
      if (!_selected.remove(pick)) _selected.add(pick);
    });
  }

  void _selectAll() {
    setState(() {
      _selected
        ..clear()
        ..addAll([
          for (final r in _runs) _Pick(_Kind.run, r.id),
          for (final a in _archives) _Pick(_Kind.archive, a.id),
          for (final l in _linkRuns) _Pick(_Kind.link, l.id),
        ]);
    });
  }

  Future<void> _delete(RecordInfo rec) async {
    final label = rec.isArchive ? '这份存档' : '这条测试记录';
    final ok = await _confirm('删除$label？\n${rec.id}\n\n删除后不可恢复');
    if (!ok) return;
    try {
      if (rec.isArchive) {
        await History.deleteArchive(rec.id);
      } else {
        await History.deleteRun(rec.id);
      }
      await _reload();
    } catch (e) {
      _toast('删除失败：$e');
    }
  }

  Future<void> _deleteLinkRun(LinkTestRun run) async {
    final ok = await _confirm('删除这条链路测速记录？\n${_fmtTime(run.createdAt)}\n\n删除后不可恢复');
    if (!ok) return;
    await LinkTestStore().delete(run.id);
    await _reload();
  }

  /// 多选删除：按种类分发到三个删除入口，单条失败不影响其余。
  Future<void> _deleteSelected() async {
    final picks = _selected.toList();
    if (picks.isEmpty) return;
    final ok = await _confirm('删除选中的 ${picks.length} 项？\n\n删除后不可恢复');
    if (!ok) return;

    var failed = 0;
    final linkIds = <String>[];
    for (final p in picks) {
      try {
        switch (p.kind) {
          case _Kind.run:
            await History.deleteRun(p.id);
          case _Kind.archive:
            await History.deleteArchive(p.id);
          case _Kind.link:
            linkIds.add(p.id);
        }
      } on Object {
        failed++;
      }
    }
    if (linkIds.isNotEmpty) {
      try {
        await LinkTestStore().deleteMany(linkIds);
      } on Object {
        failed += linkIds.length;
      }
    }

    await _reload();
    if (failed > 0) _toast('有 $failed 项删除失败，其余已删除');
  }

  Future<bool> _confirm(String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openRun(RecordInfo rec) async {
    try {
      await context.read<AppState>().loadRun(rec.id);
      if (!mounted) return;
      // 载入的是该次测试的 rows，直接看结果页；TestPage 是重新跑测试的地方。
      Navigator.of(context)
          .push(GlassRoute(builder: (_) => const ResultPage()))
          .then((_) => _reload());
    } catch (e) {
      _toast('载入失败：$e');
    }
  }

  Future<void> _openArchive(RecordInfo rec) async {
    try {
      final body = await History.readArchive(rec.id);
      if (!mounted) return;
      await Navigator.of(context).push(
        GlassRoute(builder: (_) => TestPage(initialInput: body)),
      );
      await _reload();
    } catch (e) {
      _toast('载入失败：$e');
    }
  }

  /// 打开一条链路测速记录：把结果载回 AppState，再进 VLESS 测试页。
  ///
  /// 为什么要进那个页面而不是只显示详情：历史记录的价值是「回看后再推送」，
  /// 而推送入口（勾选节点 → 推送 N）本来就在 VLESS 页。只给一个只读弹层，
  /// 用户到不了推送页，等于这条记录只能看不能用。
  Future<void> _openLinkRun(LinkTestRun run) async {
    final state = context.read<AppState>();
    state.loadLinkRun(run);
    final targets = <String>[
      for (final r in run.results)
        if (r.host.isNotEmpty && r.port > 0) '${r.host}:${r.port}',
    ];
    final links = state.settings.vlessLinks;
    await Navigator.of(context).push(
      GlassRoute(
        builder: (_) => VlessTestPage(
          targets: targets,
          template: links.isEmpty ? '' : links.first,
        ),
      ),
    );
    if (mounted) await _reload();
  }

  static String _modeLabel(LinkTestMode mode) => switch (mode) {
        LinkTestMode.auto => '一键测试',
        LinkTestMode.latency => '延迟测试',
        LinkTestMode.speed => '速度测试',
      };

  static String _fmtTime(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  /// 失败态：说清「读不出来」和下一步，而不是永远转圈。
  Widget _errorView(ThemeData theme) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_off_outlined,
                  size: 44, color: theme.colorScheme.outline),
              const SizedBox(height: 14),
              Text('记录没有加载出来', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _reload,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );

  /// 分组卡片：标题 + 条数 + （非选择态时的）单项删除入口。
  Widget _section({
    required ThemeData theme,
    required String title,
    required int count,
    required bool isEmpty,
    required String emptyText,
    required List<Widget> rows,
  }) {
    return GlassCard(
      shadow: false,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Row(
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const Spacer(),
                Text('$count 条', style: theme.textTheme.labelSmall),
              ],
            ),
          ),
          if (isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
              child: Text(emptyText, style: const TextStyle(fontSize: 12.5)),
            )
          else
            for (final row in rows) row,
        ],
      ),
    );
  }

  /// 选择态下每行左侧的勾选框；非选择态返回 null（ListTile 不占位）。
  Widget? _leading(_Pick pick, {Widget? icon}) {
    if (!_selecting) return icon;
    return Checkbox(
      value: _selected.contains(pick),
      onChanged: (_) => _togglePick(pick),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: GlassAppBar(
        title: _selecting ? null : '记录',
        titleWidget: _selecting ? Text('已选 ${_selected.length} 项') : null,
        actions: [
          if (_runs.isNotEmpty || _archives.isNotEmpty || _linkRuns.isNotEmpty)
            IconButton(
              tooltip: _selecting ? '取消选择' : '多选',
              onPressed: _toggleSelecting,
              icon: Icon(_selecting ? Icons.close : Icons.checklist),
            ),
          if (!_selecting)
            IconButton(onPressed: _reload, icon: const Icon(Icons.refresh)),
        ],
      ),
      // 底部 SafeArea：Scaffold 的 body 不会自动避让系统手势条 / 三键导航，
      // 不包这层底部内容会被系统栏压住。
      // top: false —— 顶部已由 AppBar 处理。
      body: SafeArea(
        top: false,
        child: _error != null
            ? _errorView(theme)
            : _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _reload,
                    child: ListView(
                      // 底部 24 是纯视觉呼吸：系统手势条已由外层 SafeArea 避让。
                      // 选择态下再多留一点，避免最后一行被底部操作条压住。
                      padding: EdgeInsets.fromLTRB(14, 14, 14, _selecting ? 88 : 24),
                      children: [
                        _section(
                          theme: theme,
                          title: '测试历史',
                          count: _runs.length,
                          isEmpty: _runs.isEmpty,
                          emptyText: '暂无记录，先跑一次本地测试',
                          rows: [
                            for (final r in _runs)
                              _runTile(theme, r),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _section(
                          theme: theme,
                          title: 'VLESS 链路测速',
                          count: _linkRuns.length,
                          isEmpty: _linkRuns.isEmpty,
                          emptyText: '暂无记录，去 VLESS 测试页跑一轮',
                          rows: [
                            for (final l in _linkRuns) _linkTile(theme, l),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _section(
                          theme: theme,
                          title: 'Censys 存档',
                          count: _archives.length,
                          isEmpty: _archives.isEmpty,
                          emptyText: '暂无存档，抓取成功会自动存一份',
                          rows: [
                            for (final a in _archives) _archiveTile(theme, a),
                          ],
                        ),
                      ],
                    ),
                  ),
      ),
      bottomNavigationBar: _selecting
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: _selected.isEmpty ? _selectAll : () => setState(() => _selected.clear()),
                      child: Text(_selected.isEmpty ? '全选' : '取消勾选'),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _selected.isEmpty ? null : _deleteSelected,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: Text('删除 ${_selected.length} 项'),
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }

  Widget _runTile(ThemeData theme, RecordInfo r) {
    final pick = _Pick(_Kind.run, r.id);
    return ListTile(
      dense: true,
      leading: _leading(pick),
      onTap: () => _selecting ? _togglePick(pick) : _openRun(r),
      title: Text(r.at, style: const TextStyle(fontSize: 13)),
      subtitle: Text(
        '${r.usable} / ${r.total} 可用',
        style: const TextStyle(fontSize: 11.5),
      ),
      trailing: _selecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  r.fastest > 0 ? '${r.fastest.toStringAsFixed(2)} MiB/s' : '—',
                  style: TextStyle(fontSize: 11.5, color: theme.colorScheme.primary),
                ),
                IconButton(
                  iconSize: 18,
                  onPressed: () => _delete(r),
                  icon: Icon(Icons.close, color: theme.hintColor),
                ),
              ],
            ),
    );
  }

  Widget _archiveTile(ThemeData theme, RecordInfo a) {
    final pick = _Pick(_Kind.archive, a.id);
    return ListTile(
      dense: true,
      leading: _leading(pick),
      onTap: () => _selecting ? _togglePick(pick) : _openArchive(a),
      title: Text(a.at, style: const TextStyle(fontSize: 13)),
      // 命中数从文件头里取；取不到（格式差异 / 老存档）
      // 就写「存档」，不要显示「0 命中」这种误导。
      subtitle: Text(a.total > 0 ? '${a.total} 命中' : '存档',
          style: const TextStyle(fontSize: 11.5)),
      trailing: _selecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${(a.bytes / 1024).toStringAsFixed(0)} KB',
                    style: TextStyle(fontSize: 11.5, color: theme.hintColor)),
                IconButton(
                  iconSize: 18,
                  onPressed: () => _delete(a),
                  icon: Icon(Icons.close, color: theme.hintColor),
                ),
              ],
            ),
    );
  }

  Widget _linkTile(ThemeData theme, LinkTestRun run) {
    final pick = _Pick(_Kind.link, run.id);
    final fastest = run.fastest;
    return ListTile(
      dense: true,
      leading: _leading(pick),
      onTap: () => _selecting ? _togglePick(pick) : _openLinkRun(run),
      title: Text(_fmtTime(run.createdAt), style: const TextStyle(fontSize: 13)),
      subtitle: Text(
        '${_modeLabel(run.mode)} · ${run.okCount}/${run.results.length} 可用',
        style: const TextStyle(fontSize: 11.5),
      ),
      trailing: _selecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  fastest > 0 ? '${fastest.toStringAsFixed(2)} MiB/s' : '—',
                  style: TextStyle(fontSize: 11.5, color: theme.colorScheme.primary),
                ),
                IconButton(
                  iconSize: 18,
                  onPressed: () => _deleteLinkRun(run),
                  icon: Icon(Icons.close, color: theme.hintColor),
                ),
              ],
            ),
    );
  }
}
