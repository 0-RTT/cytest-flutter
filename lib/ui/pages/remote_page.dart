import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/remote.dart';
import '../../state/app_state.dart';

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

  @override
  void dispose() {
    _data.dispose();
    _logScroll.dispose();
    super.dispose();
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

    try {
      final rows = await RemoteRunner.run(
        settings: state.settings,
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
      if (mounted) setState(() => _running = false);
    }
  }

  void _useTestInput() {
    final state = context.read<AppState>();
    setState(() {
      // 复用最近一次测试的输入文件内容
      _data.text = state.lastRunDir != null ? _data.text : _data.text;
    });
    _toast('请从「记录 → 存档」载入候选数据');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = context.watch<AppState>().settings;

    return Scaffold(
      appBar: AppBar(
        title: const Text('远程执行'),
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
      // 底部 SafeArea：Scaffold 的 body 不会自动避让系统手势条 / 三键导航，
      // 不包这层底部内容会被系统栏压住。
      // top: false —— 顶部已由 AppBar 处理。
      body: SafeArea(
        top: false,
        child: ListView(
          // 底部 24 是纯视觉呼吸：系统手势条已由外层 SafeArea 避让。
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
          children: [
            Card(
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
                        Text('候选数据', style: theme.textTheme.titleSmall),
                        const Spacer(),
                        TextButton(
                          onPressed: _useTestInput,
                          child: const Text('说明'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _data,
                      maxLines: 6,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        // monospace 在 Android 上不含中文字形，缺 fallback 中文显示方块
                        fontFamilyFallback: ['sans-serif'],
                        fontSize: 11.5,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                        hintText: '粘贴 Censys JSON，或从「记录 → 存档」载入',
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
                        Text('远端输出', style: theme.textTheme.titleSmall),
                        const Spacer(),
                        Text(_running ? '执行中' : '${_log.length} 行',
                            style: theme.textTheme.labelSmall),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 220,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: _log.isEmpty
                          ? Center(
                              child: Text('未执行',
                                  style: TextStyle(
                                      color:
                                          theme.colorScheme.onSurfaceVariant)),
                            )
                          : ListView.builder(
                              controller: _logScroll,
                              padding: const EdgeInsets.all(10),
                              itemCount: _log.length,
                              itemBuilder: (_, i) => Text(
                                _log[i],
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  // 远端日志常含中文，必须回落系统字体
                                  fontFamilyFallback: ['sans-serif'],
                                  fontSize: 11.5,
                                ),
                              ),
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
