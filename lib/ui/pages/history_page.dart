import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/history.dart';
import '../../state/app_state.dart';
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

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    final runs = await History.listRuns();
    final archives = await History.listArchives();
    if (!mounted) return;
    setState(() {
      _runs = runs;
      _archives = archives;
      _loading = false;
    });
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
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const TestPage()))
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
        MaterialPageRoute(builder: (_) => TestPage(initialInput: body)),
      );
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('载入失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('记录'),
        actions: [
          IconButton(onPressed: _reload, icon: const Icon(Icons.refresh)),
        ],
      ),
      // 底部 SafeArea：Scaffold 的 body 不会自动避让系统手势条 / 三键导航，
      // 不包这层底部内容会被系统栏压住。
      // top: false —— 顶部已由 AppBar 处理。
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _reload,
                child: ListView(
                  // 底部 24 是纯视觉呼吸：系统手势条已由外层 SafeArea 避让。
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                  children: [
                    Card(
                      margin: EdgeInsets.zero,
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
                    Card(
                      margin: EdgeInsets.zero,
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
                                subtitle: Text('${a.total} 命中',
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
