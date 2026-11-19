import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/github.dart';
import '../../data/mihomo.dart';
import '../../data/publish.dart';
import '../../state/app_state.dart';
import '../widgets/glass.dart';
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
  late final TextEditingController _subPath =
      TextEditingController(text: 'cytest-sub.txt');
  late final TextEditingController _yamlPath =
      TextEditingController(text: 'config.yaml');

  static const _previewKey = ValueKey('publish_preview_panel');

  final _previewScroll = ScrollController();
  String _mode = 'sub';

  /// 推 GitHub 时是否走本机 VLESS 代理。默认直连（国内网络通常可达 API）。
  /// 打开后临时起一条 Xray，推完立即关闭 —— 与 Kotlin `github.viaProxy` 一致。
  bool _useProxy = false;
  bool _busy = false;

  /// mihomo 高级选项（默认与 Kotlin MihomoOptions / 生成器一致，全开）。
  MihomoOptions _options = const MihomoOptions();
  bool _advanced = false;
  late final TextEditingController _lanDns = TextEditingController();

  PublishBundle? _bundle;
  String? _error;

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  @override
  void dispose() {
    _template.dispose();
    _subPath.dispose();
    _yamlPath.dispose();
    _previewScroll.dispose();
    _lanDns.dispose();
    super.dispose();
  }

  /// 模板一改就重算产物；失败时保留错误原因，不让用户对着旧内容推送。
  void _rebuild() {
    try {
      _bundle = buildPublish(
        template: _template.text,
        targets: widget.targets,
        options: _options,
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
        parseRepoSlug(state.settings.githubRepo).isEmpty) {
      _toast('先在「设置 → GitHub 推送」填仓库地址和 Token');
      return;
    }
    setState(() => _busy = true);
    int? proxyPort;
    try {
      if (_useProxy) {
        if (state.settings.vlessLinks.isEmpty) {
          throw const PublishException('走代理需要先在「线路与代理」填 VLESS 链接');
        }
        await state.startProxyLine(null);
        proxyPort = state.xray.running ? state.xray.port : null;
        if (proxyPort == null) throw const PublishException('代理线路启动失败');
      }
      await GitHub.push(
        token: state.settings.githubToken,
        repo: state.settings.githubRepo,
        path: path,
        content: _content,
        proxyPort: proxyPort,
      );
      _toast('已推送到 $path${_useProxy ? '（走代理）' : ''}');
    } catch (e) {
      _toast('推送失败：$e');
    } finally {
      if (proxyPort != null) {
        try {
          await state.stopProxyLine();
        } catch (_) {}
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyFromPanel() => _copy();

  /// mihomo 高级选项：每项改动都立刻重算 YAML，预览随之更新。
  Widget _advancedPanel(ThemeData theme) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          children: [
            _switchRow(
              theme,
              'TUN 模式',
              '接管全部流量，需要内核支持',
              _options.tun,
              (v) => _setOptions(_options.copyWith(tun: v)),
            ),
            _switchRow(
              theme,
              '自动选择组',
              '两个以上节点时生成 url-test',
              _options.autoGroup,
              (v) => _setOptions(_options.copyWith(autoGroup: v)),
            ),
            _switchRow(
              theme,
              '节点 UDP',
              '关闭后 UDP 流量不走代理',
              _options.udp,
              (v) => _setOptions(_options.copyWith(udp: v)),
            ),
            _switchRow(
              theme,
              'IPv6',
              '关闭可避免部分网络下的解析异常',
              _options.ipv6,
              (v) => _setOptions(_options.copyWith(ipv6: v)),
            ),
            _switchRow(
              theme,
              '拦截广告',
              '引入 reject 规则集，体积较大',
              _options.blockAds,
              (v) => _setOptions(_options.copyWith(blockAds: v)),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _lanDns,
              onChanged: (v) =>
                  _setOptions(_options.copyWith(lanDns: v.trim())),
              maxLines: 1,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: ['sans-serif'],
                fontSize: 12,
              ),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                labelText: '内网 DNS（可选）',
                hintText: '192.168.1.1',
              ),
            ),
          ],
        ),
      );

  void _setOptions(MihomoOptions next) {
    _options = next;
    _rebuild();
    setState(() {});
  }

  Widget _switchRow(
    ThemeData theme,
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) =>
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        title: Text(title, style: theme.textTheme.bodyMedium),
        subtitle: Text(subtitle, style: theme.textTheme.labelSmall),
        value: value,
        onChanged: _busy ? null : onChanged,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nodePreview = widget.targets.take(6).join('  ');
    final more = widget.targets.length > 6
        ? ' … 共 ${widget.targets.length} 个'
        : '';

    return Scaffold(
      appBar: const GlassAppBar(title: '推送'),
      body: SafeArea(
        top: false,
        // 整页可滚：模板/产物/高级选项内容较多，键盘弹出时 Column 会把
        // 预览区压到比标题栏还小，进而 RenderFlex 溢出。
        child: ListView(
          padding: EdgeInsets.zero,
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
                          ButtonSegment(value: 'sub', label: Text('base64')),
                          ButtonSegment(value: 'yaml', label: Text('yaml')),
                        ],
                        selected: {_mode},
                        onSelectionChanged: (s) =>
                            setState(() => _mode = s.first),
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                            visualDensity: VisualDensity.compact),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: Text('GitHub 访问',
                                style: theme.textTheme.labelLarge),
                          ),
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(value: false, label: Text('直连')),
                              ButtonSegment(value: true, label: Text('走代理')),
                            ],
                            selected: {_useProxy},
                            onSelectionChanged: _busy
                                ? null
                                : (s) => setState(() => _useProxy = s.first),
                            showSelectedIcon: false,
                            style: const ButtonStyle(
                                visualDensity: VisualDensity.compact),
                          ),
                        ],
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
                      // 高级选项只影响 YAML，base64 模式下不显示。
                      if (_mode == 'yaml') ...[
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () =>
                                setState(() => _advanced = !_advanced),
                            icon: Icon(
                              _advanced
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              size: 18,
                            ),
                            label: const Text('高级选项'),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                        ),
                        if (_advanced)
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 200),
                            child: SingleChildScrollView(
                              child: _advancedPanel(theme),
                            ),
                          ),
                      ],
                      const SizedBox(height: 10),
                      // 推送按钮独占整行：复制能力已由下方预览面板的
                      // 「复制内容」按钮提供，这里不再重复。
                      FilledButton.icon(
                        onPressed: _busy || _error != null ? null : _push,
                        icon: _busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.upload, size: 17),
                        label: Text(_busy ? '推送中…' : '推送 GitHub'),
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
            SizedBox(
              height: 280,
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
