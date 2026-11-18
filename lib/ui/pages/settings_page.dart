import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/file_pick.dart';
import '../../data/github.dart';
import '../../state/app_state.dart';

/// 设置页。
///
/// 版式约定（Material 3 + Flutter 原生控件）：
/// - 每个分区是一张无阴影卡片，标题行 = 图标方块 + 标题 + 一行说明；
/// - 输入项统一用 `filled` 圆角输入框，单位用 `suffixText` 贴在框内；
/// - 「保存」固定在底部操作条，拇指可达，滚动时不会滚走。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _sha1;
  late TextEditingController _latency;
  late TextEditingController _speed;
  late TextEditingController _maxLatency;
  late TextEditingController _dial;
  late TextEditingController _download;
  late TextEditingController _speedUrl;
  late TextEditingController _ghRepo;
  late TextEditingController _ghToken;
  late TextEditingController _remoteHost;
  late TextEditingController _remotePort;
  late TextEditingController _remoteUser;
  late TextEditingController _remotePassword;
  late TextEditingController _remoteKey;
  late TextEditingController _vless;

  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    final s = context.read<AppState>().settings;
    _sha1 = TextEditingController(text: '${s.sha1Concurrency}');
    _latency = TextEditingController(text: '${s.latencyConcurrency}');
    _speed = TextEditingController(text: '${s.speedConcurrency}');
    _maxLatency = TextEditingController(text: '${s.maxLatency}');
    _dial = TextEditingController(text: '${s.dialTimeout}');
    _download = TextEditingController(text: '${s.downloadTimeout}');
    _speedUrl = TextEditingController(text: s.speedUrl);
    _ghRepo = TextEditingController(text: s.githubRepo);
    _ghToken = TextEditingController(text: s.githubToken);
    _remoteHost = TextEditingController(text: s.remoteHost);
    _remotePort = TextEditingController(text: '${s.remotePort}');
    _remoteUser = TextEditingController(text: s.remoteUser);
    _remotePassword = TextEditingController(text: s.remotePassword);
    _remoteKey = TextEditingController(text: s.remoteKeyPath);
    _vless = TextEditingController(text: s.vlessLinks.join('\n'));
    _loaded = true;
  }

  @override
  void dispose() {
    for (final c in [
      _sha1, _latency, _speed, _maxLatency, _dial, _download,
      _speedUrl, _ghRepo, _ghToken,
      _remoteHost, _remotePort, _remoteUser, _remotePassword, _remoteKey,
      _vless,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    final s = state.settings;

    // 仓库地址允许用户直接粘网页链接，先规范化成 owner/repo 再落库，
    // 这样发布页 / GitHub.push 都不用重复解析。
    final repoInput = _ghRepo.text.trim();
    final repoSlug = parseRepoSlug(repoInput);
    if (repoInput.isNotEmpty && repoSlug.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('仓库地址格式不对，应形如 https://github.com/owner/repo'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    s.sha1Concurrency = int.tryParse(_sha1.text) ?? s.sha1Concurrency;
    s.latencyConcurrency = int.tryParse(_latency.text) ?? s.latencyConcurrency;
    s.speedConcurrency = int.tryParse(_speed.text) ?? s.speedConcurrency;
    s.maxLatency = int.tryParse(_maxLatency.text) ?? s.maxLatency;
    s.dialTimeout = int.tryParse(_dial.text) ?? s.dialTimeout;
    s.downloadTimeout = int.tryParse(_download.text) ?? s.downloadTimeout;
    s.speedUrl = _speedUrl.text.trim();
    s.githubRepo = repoSlug;
    s.githubToken = _ghToken.text.trim();
    s.remoteHost = _remoteHost.text.trim();
    s.remotePort = int.tryParse(_remotePort.text) ?? 22;
    s.remoteUser = _remoteUser.text.trim();
    s.remotePassword = _remotePassword.text;
    s.remoteKeyPath = _remoteKey.text.trim();
    s.vlessLinks = _lines(_vless.text);
    // 回填规范化结果，让用户看到实际生效的 owner/repo。
    _ghRepo.text = repoSlug;
    await state.saveSettings();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('设置已保存')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _theme = theme;
    final lineProxyCount = context.watch<AppState>().settings.proxyIps.length;
    if (!_loaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(_bind);
      });
    }

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      // 底部 SafeArea：Scaffold 的 body 不会自动避让系统手势条 / 三键导航。
      // top: false —— 顶部已由 AppBar 处理。
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 20),
                  children: [
                    _section(
                      theme,
                      icon: Icons.route_outlined,
                      title: '线路与代理',
                      hint: '抓取与测速的出入口',
                      children: [
                        _multiline('VLESS 链接', _vless,
                            hint: 'vless://uuid@host:443?type=xhttp&security=tls&...'),
                        _caption(theme, '每行一条，取第一条可解析的'),
                        const SizedBox(height: 12),
                        _proxyIpsRow(theme, lineProxyCount),
                        const SizedBox(height: 6),
                        _caption(theme,
                            '从文件加载，不在此展示内容；使用时自动替换 VLESS 路径里的回源 ip:port。'),
                      ],
                    ),
                    _section(
                      theme,
                      icon: Icons.speed_outlined,
                      title: '并发',
                      hint: '过高会互相抢带宽，单条读数偏低',
                      children: [
                        _num('指纹筛选并发', _sha1, hint: '默认 30'),
                        _num('延迟测试并发', _latency, hint: '默认 100'),
                        _num('速度测试并发', _speed, hint: '默认 3，建议 3-6'),
                        // 阈值只用来省测速时间，不负责判定可用。
                        // 这条 helper 是刻意的：用户看到「延迟 800ms」就以为节点废了，
                        // 于是在设置里填 200，结果一键测试全被筛掉。
                        _num(
                          '延迟上限（ms）',
                          _maxLatency,
                          hint: '0 = 不限（推荐）',
                          helper: '只用于「一键测试」时跳过太慢的候选以节省测速时间，'
                              '不代表节点不可用；「延迟测试」不受此项影响。',
                        ),
                      ],
                    ),
                    _section(
                      theme,
                      icon: Icons.timer_outlined,
                      title: '超时',
                      hint: '网络抖动大时适当放宽',
                      children: [
                        _num('连接超时（秒）', _dial, hint: '默认 5'),
                        _num('下载超时（秒）', _download, hint: '默认 10'),
                      ],
                    ),
                    _section(
                      theme,
                      icon: Icons.download_outlined,
                      title: '测速',
                      hint: '窗口 3s / 上限 64MiB，首 256KiB 预热丢弃',
                      children: [
                        // 只有测速地址一项：抓取走什么代理由「线路与代理」的
                        // VLESS 链接决定，不再单独配一个抓取代理（那是同一件事
                        // 的第二份开关，两个值必然漂移）。
                        _text('测速地址', _speedUrl),
                      ],
                    ),
                    _section(
                      theme,
                      icon: Icons.cloud_upload_outlined,
                      title: 'GitHub 推送',
                      hint: '把订阅写到仓库文件',
                      children: [
                        _text('仓库地址', _ghRepo,
                            hint: 'https://github.com/0-RTT/sub'),
                        _text('Token', _ghToken,
                            obscure: true, hint: '需要 repo contents 写权限'),
                      ],
                    ),
                    _section(
                      theme,
                      icon: Icons.dns_outlined,
                      title: '远程执行',
                      hint: 'SSH 到服务器跑三阶段',
                      children: [
                        _text('主机', _remoteHost, hint: '1.2.3.4'),
                        _num('端口', _remotePort, hint: '默认 22'),
                        _text('用户', _remoteUser, hint: '默认 root'),
                        _text('密码', _remotePassword, obscure: true),
                        _text('私钥路径', _remoteKey, hint: '留空则用密码'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        '参数保存在本机（SharedPreferences），下次启动自动恢复',
                        style: theme.textTheme.labelSmall,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _saveBar(theme),
          ],
        ),
      ),
    );
  }

  /// 底部固定操作条：保存按钮常驻，不随列表滚走。
  Widget _saveBar(ThemeData theme) => Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              width: 0.5,
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: SizedBox(
          height: 46,
          child: FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('保存'),
          ),
        ),
      );

  List<String> _lines(String text) =>
      text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  /// 导入 proxyip 文件（4 列 CSV 或每行 ip:port），只显示条目数、不展示内容。
  Future<void> _importProxyIps() async {
    final state = context.read<AppState>();
    try {
      final text = await pickTextFile();
      if (text == null) return; // 用户取消
      final count = await state.importProxyIps(text);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入 $count 条 proxyip')),
      );
    } on FilePickException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }

  Future<void> _clearProxyIps() async {
    await context.read<AppState>().clearProxyIps();
    if (!mounted) return;
    setState(() {});
  }

  /// proxyip 一行：只读徽标 + 加载 + 清空。
  ///
  /// 360dp 窄屏实测：徽标 +「加载文件」+「清空」三个元素并排会溢出 3px，
  /// 所以清空改成紧凑 IconButton，徽标用 Flexible 兜住极端字数。
  Widget _proxyIpsRow(ThemeData theme, int count) => Row(
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'proxyip $count 条',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSecondaryContainer),
              ),
            ),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: _importProxyIps,
            icon: const Icon(Icons.file_open_outlined, size: 16),
            label: const Text('加载文件'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
          IconButton(
            onPressed: count == 0 ? null : _clearProxyIps,
            tooltip: '清空 proxyip',
            icon: const Icon(Icons.delete_outline, size: 18),
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(
              minimumSize: const Size(34, 34),
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      );

  /// 一个分区卡片：图标方块 + 标题 + 说明 + 分隔线 + 内容。
  Widget _section(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String hint,
    required List<Widget> children,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          width: 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon,
                      size: 18, color: theme.colorScheme.onPrimaryContainer),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 1),
                      Text(
                        hint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _caption(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(text,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      );

  /// filled 圆角输入框：M3 的默认气质，也比 Outline 更省视觉噪音。
  InputDecoration _decoration({
    required String label,
    String? hint,
    String? helper,
    String? suffix,
    Widget? prefixIcon,
    bool obscure = false,
  }) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 2,
        suffixText: suffix,
        prefixIcon: prefixIcon,
        filled: true,
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: (_theme ?? ThemeData.light()).colorScheme.primary,
            width: 1.2,
          ),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      );

  /// 最近一次 build 的 Theme：输入框装饰器在 build 之外组装，需要它取焦点色。
  ThemeData? _theme;

  Widget _num(
    String label,
    TextEditingController c, {
    String? hint,
    String? helper,
    String? suffix,
  }) =>
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          decoration:
              _decoration(label: label, hint: hint, helper: helper, suffix: suffix),
        ),
      );

  Widget _text(String label, TextEditingController c,
          {String? hint, bool obscure = false}) =>
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: TextField(
          controller: c,
          obscureText: obscure,
          style: const TextStyle(fontSize: 13),
          decoration: _decoration(label: label, hint: hint, obscure: obscure),
        ),
      );

  Widget _multiline(String label, TextEditingController c, {String? hint}) =>
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: TextField(
          controller: c,
          maxLines: 4,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontFamilyFallback: <String>['sans-serif'],
            fontSize: 11.5,
          ),
          decoration: _decoration(label: label, hint: hint),
        ),
      );
}
