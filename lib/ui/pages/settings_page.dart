import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/file_pick.dart';
import '../../data/github.dart';
import '../../state/app_state.dart';

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
  late TextEditingController _httpProxy;
  late TextEditingController _fetchProxy;
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
    _httpProxy = TextEditingController(text: s.httpProxy);
    _fetchProxy = TextEditingController(text: s.fetchProxy);
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
      _speedUrl, _httpProxy, _fetchProxy, _ghRepo, _ghToken,
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
    s.httpProxy = _httpProxy.text.trim();
    s.fetchProxy = _fetchProxy.text.trim();
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
    final lineProxyCount = context.watch<AppState>().settings.proxyIps.length;
    if (!_loaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(_bind);
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: FilledButton(onPressed: _save, child: const Text('保存')),
          ),
        ],
      ),
      // 底部 SafeArea：Scaffold 的 body 不会自动避让系统手势条 / 三键导航，
      // 不包这层底部内容会被系统栏压住。
      // top: false —— 顶部已由 AppBar 处理。
      body: SafeArea(
        top: false,
        child: Form(
          key: _formKey,
          child: ListView(
            // 底部 24 是纯视觉呼吸：系统手势条已由外层 SafeArea 避让。
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
            children: [
              _section(theme, '线路与代理', '抓取与测速的出入口', [
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextField(
                    controller: _vless,
                    maxLines: 4,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontFamilyFallback: <String>['sans-serif'],
                      fontSize: 11.5,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'VLESS 链接',
                      hintText:
                          'vless://uuid@host:443?type=xhttp&security=tls&...',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text('每行一条，取第一条可解析的',
                    style: theme.textTheme.labelSmall),
                const SizedBox(height: 10),
                // 标题与按钮分两行：360dp 下放进同一行会溢出 40px。
                Row(
                  children: [
                    Text('proxyip', style: theme.textTheme.bodySmall),
                    const SizedBox(width: 8),
                    Text('已加载 $lineProxyCount 条',
                        style: theme.textTheme.labelSmall),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _importProxyIps,
                      icon: const Icon(Icons.file_open_outlined, size: 16),
                      label: const Text('加载文件'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    const SizedBox(width: 4),
                    TextButton(
                      onPressed: lineProxyCount == 0 ? null : _clearProxyIps,
                      child: const Text('清空'),
                    ),
                  ],
                ),
                Text(
                  '从文件加载，不在此展示内容；使用时自动替换 VLESS 路径里的回源 ip:port。',
                  style: theme.textTheme.labelSmall,
                ),
              ]),
              _section(theme, '并发', '测速并发过高会互相抢带宽，单条读数偏低', [
                _num('指纹筛选并发', _sha1, hint: '默认 30'),
                _num('延迟测试并发', _latency, hint: '默认 100'),
                _num('速度测试并发', _speed, hint: '默认 2，建议 4-6'),
                _num('延迟上限（ms）', _maxLatency, hint: '0 表示不限'),
              ]),
              _section(theme, '超时', '网络抖动大时适当放宽', [
                _num('连接超时（秒）', _dial, hint: '默认 5'),
                _num('下载超时（秒）', _download, hint: '默认 10'),
              ]),
              _section(theme, '测速', '窗口 3s / 上限 64MiB，首 256KiB 预热丢弃', [
                _text('测速地址', _speedUrl),
                _text('测速代理', _httpProxy, hint: '可选，留空直连'),
                _text('抓取代理', _fetchProxy, hint: 'WebView 抓取用，留空走 Xray 或直连'),
              ]),
              _section(theme, 'GitHub 推送', '把订阅写到仓库文件', [
                _text('仓库地址', _ghRepo,
                    hint: 'https://github.com/0-RTT/sub'),
                _text('Token', _ghToken,
                    obscure: true, hint: '需要 repo contents 写权限'),
              ]),
              _section(theme, '远程执行', 'SSH 到服务器跑三阶段', [
                _text('主机', _remoteHost, hint: '1.2.3.4'),
                _num('端口', _remotePort, hint: '默认 22'),
                _text('用户', _remoteUser, hint: '默认 root'),
                _text('密码', _remotePassword, obscure: true),
                _text('私钥路径', _remoteKey, hint: '留空则用密码'),
              ]),
              const SizedBox(height: 20),
              Center(
                child: Text(
                  '参数保存在本机（SharedPreferences），下次启动自动恢复',
                  style: theme.textTheme.labelSmall,
                ),
              ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }

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

  Widget _section(ThemeData theme, String title, String hint, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _num(String label, TextEditingController c, {String? hint}) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
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
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );
}
