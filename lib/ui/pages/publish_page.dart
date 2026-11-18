import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/github.dart';
import '../../data/publish.dart';
import '../../state/app_state.dart';
import '../widgets/log_panel.dart';

/// 推送页：一条 vless 模板链接 + 从结果页选中的 ip:port，
/// 自动替换生成 base64 订阅与 mihomo YAML，再择一推送到 GitHub。
class PublishPage extends StatefulWidget {
  const PublishPage({
    super.key,
    required this.targets,
    this.template = '',
  });

  /// 从结果页带过来的 `ip:port` 列表（只含测速成功且被勾选的）。
  final List<String> targets;

  /// 预填的 vless 模板链接（默认取设置页第一条）。
  final String template;

  @override
  State<PublishPage> createState() => _PublishPageState();
}

class _PublishPageState extends State<PublishPage> {
  late final TextEditingController _template =
      TextEditingController(text: widget.template);
  late final TextEditingController _subPath = TextEditingController();
  late final TextEditingController _yamlPath =
      TextEditingController(text: 'config.yaml');

  static const _previewKey = ValueKey('publish_preview_panel');

  final _previewScroll = ScrollController();
  String _mode = 'sub';
  bool _busy = false;
  PublishBundle? _bundle;
  String? _error;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>().settings;
    _subPath.text = s.githubPath.trim().isEmpty
        ? 'cytest-sub.txt'
        : s.githubPath.trim();
    _rebuild();
  }

  @override
  void dispose() {
    _template.dispose();
    _subPath.dispose();
    _yamlPath.dispose();
    _previewScroll.dispose();
    super.dispose();
  }

  /// 模板一改就重算产物；失败时保留错误原因，不让用户对着旧内容推送。
  void _rebuild() {
    try {
      _bundle = buildPublish(
        template: _template.text,
        targets: widget.targets,
      );
      _error = _bundle!.yaml.isEmpty ? 'mihomo YAML 生成失败：候选地址无法解析' : null;
    } catch (e) {
      _bundle = null;
      _error = e is PublishException ? e.message : '生成失败：$e';
    }
  }

  String get _content {
    final b = _bundle;
    if (b == null) return '';
    return _mode == 'sub' ? b.subscription : b.yaml;
  }

  String get _path => (_mode == 'sub' ? _subPath.text : _yamlPath.text).trim();

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _copy() async {
    if (_error != null || _content.isEmpty) {
      _toast(_error ?? '没有可复制的内容');
      return;
    }
    await Clipboard.setData(ClipboardData(text: _content));
    _toast(_mode == 'sub' ? 'base64 订阅已复制' : 'mihomo YAML 已复制');
  }

  Future<void> _push() async {
    final state = context.read<AppState>();
    if (_busy) return;
    if (_error != null || _bundle == null) {
      _toast(_error ?? '内容生成失败');
      return;
    }
    final path = _path;
    if (path.isEmpty) {
      _toast('先填文件名');
      return;
    }
    if (state.settings.githubToken.trim().isEmpty ||
        !state.settings.githubRepo.contains('/')) {
      _toast('先在「设置 → GitHub 推送」填仓库和 Token');
      return;
    }
    setState(() => _busy = true);
    try {
      await GitHub.push(
        token: state.settings.githubToken,
        repo: state.settings.githubRepo,
        path: path,
        content: _content,
      );
      _toast('已推送到 $path');
    } catch (e) {
      _toast('推送失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyFromPanel() => _copy();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nodePreview = widget.targets.take(6).join('  ');
    final more = widget.targets.length > 6
        ? ' … 共 ${widget.targets.length} 个'
        : '';

    return Scaffold(
      appBar: AppBar(title: const Text('推送')),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.link,
                              size: 17, color: theme.colorScheme.primary),
                          const SizedBox(width: 6),
                          Text('vless 模板',
                              style: theme.textTheme.titleSmall),
                          const Spacer(),
                          Text('${widget.targets.length} 个节点',
                              style: theme.textTheme.labelSmall),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _template,
                        onChanged: (_) => setState(_rebuild),
                        minLines: 2,
                        maxLines: 3,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontFamilyFallback: ['sans-serif'],
                          fontSize: 11.5,
                        ),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          isDense: true,
                          hintText:
                              'vless://uuid@1.2.3.4:443?security=tls&type=ws#模板',
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text('$nodePreview$more',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                              value: 'sub', label: Text('订阅 base64')),
                          ButtonSegment(
                              value: 'yaml', label: Text('mihomo YAML')),
                        ],
                        selected: {_mode},
                        onSelectionChanged: (s) =>
                            setState(() => _mode = s.first),
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                            visualDensity: VisualDensity.compact),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _mode == 'sub' ? _subPath : _yamlPath,
                        onChanged: (_) => setState(() {}),
                        maxLines: 1,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontFamilyFallback: ['sans-serif'],
                          fontSize: 12,
                        ),
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          isDense: true,
                          labelText: _mode == 'sub'
                              ? '订阅文件名（base64）'
                              : 'mihomo 文件名（YAML）',
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _error != null ? null : _copy,
                              icon: const Icon(Icons.copy_all_outlined,
                                  size: 17),
                              label: const Text('复制'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _busy || _error != null ? null : _push,
                              icon: _busy
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Icon(Icons.upload, size: 17),
                              label: Text(_busy ? '推送中…' : '推送 GitHub'),
                            ),
                          ),
                        ],
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
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: LogPanel(
                  key: _previewKey,
                  title: _mode == 'sub' ? 'base64 订阅预览' : 'mihomo YAML 预览',
                  lines: _error != null
                      ? const []
                      : (_mode == 'sub' || _bundle == null
                          ? [_content]
                          : _content.split('\n')),
                  emptyText: _error ?? '暂无内容',
                  scrollController: _previewScroll,
                  showJumpToLatest: false,
                  copyTooltip: '复制内容',
                  onCopy: _copyFromPanel,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
