import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/paths.dart';
import '../../data/candidates.dart';
import '../../data/history.dart';
import '../../data/remote.dart';
import '../../state/app_state.dart';
import '../widgets/glass.dart';
import '../widgets/log_panel.dart';

class RemotePage extends StatefulWidget {
  const RemotePage({super.key, this.initialInput});

  final String? initialInput;

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> {
  late final TextEditingController _data =
      TextEditingController(text: widget.initialInput ?? '');
  final _logScroll = ScrollController();
  final List<String> _log = [];
  bool _running = false;
  String? _error;

  /// 数据来源说明（「2026-11-20 12:30 存档 · 512 个候选」这种），空 = 手输。
  String _dataLabel = '';

  @override
  void dispose() {
    _data.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  /// 从已有记录里取 Censys 数据：存档 JSON 或历史测试的原始输入。
  ///
  /// 与本地测试页同一个数据来源（`cytest/archives` 与 `cytest/runs/<id>/input.txt`），
  /// 区别只是这里**不提取 ip:port**：远端引擎自己解析 JSON，
  /// 提取反而会丢掉 port/协议等字段。
  Future<void> _pickData() async {
    final picked = await showModalBottomSheet<_PickedData>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _DataPickerSheet(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _data.text = picked.content;
      _dataLabel = picked.label;
    });
  }

  Future<void> _run() async {
    final input = _data.text.trim();
    if (input.isEmpty) {
      _toast('先粘贴候选数据');
      return;
    }
    final state = context.read<AppState>();
    if (state.settings.remoteHost.trim().isEmpty) {
      _toast('先在「设置 → 远程执行」填服务器地址');
      return;
    }

    setState(() {
      _running = true;
      _error = null;
      _log.clear();
    });

    // 只关「本次任务自己拉起的」代理：用户原本就开着的那条不动，否则会
    // 把他正在用的抓取代理一起停掉。
    var startedProxyHere = false;
    try {
      int? proxyPort;
      if (state.settings.remoteUseProxy) {
        if (state.settings.vlessLinks.isEmpty) {
          throw Exception('走代理需要先在「设置 → 线路与代理」填 VLESS 链接');
        }
        if (!state.xray.running) {
          setState(() => _log.add('启动本机代理…'));
          await state.startProxyLine(null);
          startedProxyHere = true;
        }
        proxyPort = state.xray.port;
      }
      final rows = await RemoteRunner.run(
        settings: state.settings,
        proxyPort: proxyPort,
        censysJson: input,
        onLine: (line) {
          if (!mounted) return;
          setState(() => _log.add(line));
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_logScroll.hasClients) {
              _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
            }
          });
        },
      );
      if (!mounted) return;
      state.rows = rows;
      state.pushLog('远程完成：${rows.length} 条');
      _toast('完成：${rows.length} 条结果');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (startedProxyHere) {
        // 任务结束就收掉，不留一条空转的 Xray 连接（费电、也占着节点连接）。
        await state.stopProxyLine();
        if (mounted) setState(() => _log.add('已关闭本次临时拉起的代理'));
      }
      if (mounted) setState(() => _running = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  void _jumpToLatest() {
    if (_logScroll.hasClients) {
      _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    }
  }

  Future<void> _copyLogs() async {
    await Clipboard.setData(ClipboardData(text: _log.join('\n')));
    if (mounted) {
      _toast('输出已复制');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = context.watch<AppState>().settings;

    return Scaffold(
      appBar: GlassAppBar(
        title: '远程执行',
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: FilledButton(
              onPressed: _running ? null : _run,
              child: Text(_running ? '执行中…' : '在服务器上执行'),
            ),
          ),
        ],
      ),
      // 底部 SafeArea：body 不会自动避让系统手势条 / 三键导航。
      // top: false —— 顶部已由 AppBar 处理。
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
              child: Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('服务器', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 6),
                      Text(
                        s.remoteHost.isEmpty
                            ? '未配置，请到「设置 → 远程执行」填写'
                            : '${s.remoteUser}@${s.remoteHost}:${s.remotePort}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: s.remoteHost.isEmpty
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Text('访问方式',
                              style: theme.textTheme.labelMedium),
                          const Spacer(),
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(value: false, label: Text('直连')),
                              ButtonSegment(value: true, label: Text('走代理')),
                            ],
                            selected: {s.remoteUseProxy},
                            onSelectionChanged: _running
                                ? null
                                : (v) async {
                                    final state = context.read<AppState>();
                                    state.settings.remoteUseProxy = v.first;
                                    await state.saveSettings();
                                    if (mounted) setState(() {});
                                  },
                            showSelectedIcon: false,
                            style: const ButtonStyle(
                                visualDensity: VisualDensity.compact),
                          ),
                        ],
                      ),
                      if (s.remoteUseProxy)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '经本机 Xray 的 SOCKS 入站连服务器；未启动会自动拉起线路',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('候选数据', style: theme.textTheme.titleSmall),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: _running ? null : _pickData,
                            icon: const Icon(Icons.list_alt, size: 16),
                            label: const Text('从记录选择', style: TextStyle(fontSize: 12)),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _data,
                        maxLines: 4,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          // monospace 在 Android 上不含中文字形，缺 fallback 中文显示方块
                          fontFamilyFallback: ['sans-serif'],
                          fontSize: 11.5,
                        ),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          isDense: true,
                          hintText: '粘贴 Censys JSON，或点右上「从记录选择」',
                        ),
                      ),
                      if (_dataLabel.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '已载入：$_dataLabel',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // 输出模块：Expanded 独占剩余空间；bottom=14 包底，圆角完整露出。
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: LogPanel(
                        key: const ValueKey('remote_output_panel'),
                        title: '远端输出',
                        lines: _log,
                        running: _running,
                        emptyText: '未执行',
                        scrollController: _logScroll,
                        onJumpToLatest: _jumpToLatest,
                        onCopy: _copyLogs,
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!,
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

}

/// 选中的数据（原始文本 + 展示用来源标签）。
class _PickedData {
  const _PickedData(this.label, this.content);

  final String label;

  /// **原始文本**：存档是 Censys JSON，历史记录是当初喂进去的 input.txt。
  /// 不做 ip:port 提取 —— 远端引擎自己解析，提取会丢字段。
  final String content;
}

/// 记录选择弹层：上半区 Censys 存档，下半区历史测试的原始输入。
class _DataPickerSheet extends StatefulWidget {
  const _DataPickerSheet();

  @override
  State<_DataPickerSheet> createState() => _DataPickerSheetState();
}

class _DataPickerSheetState extends State<_DataPickerSheet> {
  late final Future<(List<RecordInfo>, List<RecordInfo>)> _records = _load();

  /// 正在读取的记录 id（禁用重复点击 + 显示进度）。
  String? _loadingId;

  static Future<(List<RecordInfo>, List<RecordInfo>)> _load() async {
    try {
      // 与记录页同一口径：读盘必须有上限，否则弹层一直转圈。
      final archives =
          await History.listArchives().timeout(const Duration(seconds: 10));
      final runs = await History.listRuns().timeout(const Duration(seconds: 10));
      return (archives, runs);
    } on TimeoutException {
      throw Exception('读取记录超时（10s），存储目录没有响应');
    }
  }

  /// 历史记录的原始输入：`runs/<id>/input.txt`（当初喂给引擎的那份）。
  Future<String> _readRunInput(String id) async {
    final dir = await Paths.runs();
    final file = File('${dir.path}/$id/input.txt');
    if (!await file.exists()) throw Exception('这条记录缺少 input.txt');
    return file.readAsString();
  }

  Future<void> _choose(RecordInfo info) async {
    if (_loadingId != null) return;
    setState(() => _loadingId = info.id);
    try {
      final content = info.isArchive
          ? await History.readArchive(info.id)
          : await _readRunInput(info.id);
      if (!mounted) return;
      if (content.trim().isEmpty) {
        setState(() => _loadingId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('这条记录里没有数据')),
        );
        return;
      }
      final targets = extractTargets(content).length;
      final label = targets > 0
          ? '${info.at} · $targets 个候选'
          : '${info.at} · ${(content.length / 1024).toStringAsFixed(1)} KB';
      Navigator.of(context).pop(_PickedData(label, content));
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingId = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('读取失败：$e')));
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
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('还没有可用的记录：先去「获取数据」抓一次，'
                      '或跑一次本地测试',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall),
                ),
              );
            } else {
              body = ListView(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                children: [
                  _header(theme, 'Censys 存档（${archives.length}）'),
                  if (archives.isEmpty)
                    _empty(theme, '没有存档')
                  else
                    for (final a in archives) _tile(theme, a),
                  _header(theme, '历史测试的输入（${runs.length}）'),
                  if (runs.isEmpty)
                    _empty(theme, '还没有跑过本地测试')
                  else
                    for (final r in runs) _tile(theme, r),
                ],
              );
            }
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Text('选择 Censys 数据', style: theme.textTheme.titleSmall),
                    const Spacer(),
                    Text('点一条载入', style: theme.textTheme.labelSmall),
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

  Widget _header(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
        child: Text(
          text,
          style: theme.textTheme.labelMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );

  Widget _empty(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
        child: Text(text,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.outline)),
      );

  Widget _tile(ThemeData theme, RecordInfo info) {
    final busy = _loadingId == info.id;
    final subtitle = info.isArchive
        ? (info.total > 0 ? '${info.total} 命中' : '存档')
        : (info.usable > 0 ? '${info.usable}/${info.total} 可用' : '测试记录');
    return ListTile(
      dense: true,
      enabled: _loadingId == null,
      leading: busy
          ? const SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(info.isArchive ? Icons.archive_outlined : Icons.science_outlined,
              size: 18),
      title: Text(info.at, style: const TextStyle(fontSize: 13)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 11.5)),
      onTap: () => _choose(info),
    );
  }
}
