import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/history.dart';
import '../../state/app_state.dart';
import '../widgets/glass.dart';
import 'result_page.dart';
import 'test_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<RecordInfo> _runs = const [];
  List<RecordInfo> _archives = const [];
  bool _loading = true;

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
      if (!mounted) return;
      setState(() {
        _runs = runs;
        _archives = archives;
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

  Future<void> _delete(RecordInfo rec) async {
    final label = rec.isArchive ? '这份存档' : '这条测试记录';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('删除$label？\n${rec.id}\n\n删除后不可恢复'),
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
    if (ok != true) return;
    try {
      if (rec.isArchive) {
        await History.deleteArchive(rec.id);
      } else {
        await History.deleteRun(rec.id);
      }
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：$e')));
      }
    }
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
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('载入失败：$e')));
      }
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
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('载入失败：$e')));
      }
    }
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: GlassAppBar(
        title: '记录',
        actions: [
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
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                  children: [
                    GlassCard(
                      shadow: false,
                      padding: EdgeInsets.zero,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                            child: Row(
                              children: [
                                Text('测试历史', style: theme.textTheme.titleSmall),
                                const Spacer(),
                                Text('${_runs.length} 条', style: theme.textTheme.labelSmall),
                              ],
                            ),
                          ),
                          if (_runs.isEmpty)
                            const Padding(
                              padding: EdgeInsets.fromLTRB(14, 4, 14, 14),
                              child: Text('暂无记录，先跑一次本地测试',
                                  style: TextStyle(fontSize: 12.5)),
                            )
                          else
                            for (final r in _runs)
                              ListTile(
                                dense: true,
                                onTap: () => _openRun(r),
                                title: Text(r.at, style: const TextStyle(fontSize: 13)),
                                subtitle: Text(
                                  '${r.usable} / ${r.total} 可用',
                                  style: const TextStyle(fontSize: 11.5),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      r.fastest > 0 ? '${r.fastest.toStringAsFixed(2)} MiB/s' : '—',
                                      style: TextStyle(
                                          fontSize: 11.5, color: theme.colorScheme.primary),
                                    ),
                                    IconButton(
                                      iconSize: 18,
                                      onPressed: () => _delete(r),
                                      icon: Icon(Icons.close, color: theme.hintColor),
                                    ),
                                  ],
                                ),
                              ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    GlassCard(
                      shadow: false,
                      padding: EdgeInsets.zero,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                            child: Row(
                              children: [
                                Text('Censys 存档', style: theme.textTheme.titleSmall),
                                const Spacer(),
                                Text('${_archives.length} 条', style: theme.textTheme.labelSmall),
                              ],
                            ),
                          ),
                          if (_archives.isEmpty)
                            const Padding(
                              padding: EdgeInsets.fromLTRB(14, 4, 14, 14),
                              child: Text('暂无存档，抓取成功会自动存一份',
                                  style: TextStyle(fontSize: 12.5)),
                            )
                          else
                            for (final a in _archives)
                              ListTile(
                                dense: true,
                                onTap: () => _openArchive(a),
                                title: Text(a.at, style: const TextStyle(fontSize: 13)),
                                // 命中数从文件头里取；取不到（格式差异 / 老存档）
                                // 就写「存档」，不要显示「0 命中」这种误导。
                                subtitle: Text(
                                    a.total > 0 ? '${a.total} 命中' : '存档',
                                    style: const TextStyle(fontSize: 11.5)),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text('${(a.bytes / 1024).toStringAsFixed(0)} KB',
                                        style: TextStyle(
                                            fontSize: 11.5, color: theme.hintColor)),
                                    IconButton(
                                      iconSize: 18,
                                      onPressed: () => _delete(a),
                                      icon: Icon(Icons.close, color: theme.hintColor),
                                    ),
                                  ],
                                ),
                              ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
