import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/file_pick.dart';
import '../../core/settings.dart' show Defaults;
import '../../data/github.dart';
import '../../state/app_state.dart';
import '../widgets/glass.dart';

/// 设置页：参考系统「更多」页的分组列表形态。
///
/// 版式约定：
/// - 页面底是浅灰；每个分组 = 一行灰色小标题 + 一张白色圆角卡片；
/// - 卡片里每行 = 图标 + 标题 + 当前值（副标题）+ 右箭头，行间用内缩细分割线；
/// - 点行进入底部弹层编辑该组字段，根页面只保留摘要，长表单不再把首页拉得很长；
/// - 「保存」固定在底部操作条，一次提交全部改动。
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
  late TextEditingController _latencyUrl;
  late TextEditingController _ghRepo;
  late TextEditingController _ghToken;
  late TextEditingController _remoteHost;
  late TextEditingController _remotePort;
  late TextEditingController _remoteUser;
  late TextEditingController _remotePassword;
  late TextEditingController _remoteKey;
  late TextEditingController _vless;

  bool _loaded = false;
  ThemeData? _theme;

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
    _latencyUrl = TextEditingController(text: s.latencyUrl);
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
      _sha1,
      _latency,
      _speed,
      _maxLatency,
      _dial,
      _download,
      _speedUrl,
      _latencyUrl,
      _ghRepo,
      _ghToken,
      _remoteHost,
      _remotePort,
      _remoteUser,
      _remotePassword,
      _remoteKey,
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
    // 两个地址的空串语义都是「恢复默认」，不是「关闭这一档」：
    // - 延迟地址留空会让每条线路都报「地址非法」；
    // - 速度地址留空会让三阶段的 speedTestURL 变成空串（引擎直接报配置错误）。
    // 两条必须**对称**处理，改一条漏一条最容易出事故。
    final speedInput = _speedUrl.text.trim();
    s.speedUrl = speedInput.isEmpty ? Defaults.speedUrl : speedInput;
    _speedUrl.text = s.speedUrl;
    final latencyInput = _latencyUrl.text.trim();
    s.latencyUrl = latencyInput.isEmpty ? Defaults.latencyUrl : latencyInput;
    _latencyUrl.text = s.latencyUrl;
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
    try {
      await state.saveSettings();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('设置已保存')));
      }
    } catch (e) {
      // 落盘失败必须让用户知道：过去没有 try/catch，点了保存什么反应都没有。
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _theme = theme;
    final state = context.watch<AppState>();
    final s = state.settings;
    if (!_loaded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(_bind);
      });
    }

    return Scaffold(
      appBar: const GlassAppBar(
        title: '设置',
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        top: false,
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 20),
            children: [
              _sectionHeader(theme, '线路与代理'),
              _card([
                _row(
                  theme,
                  icon: Icons.route_outlined,
                  title: 'VLESS 链接',
                  value: s.vlessLinks.isEmpty
                      ? '未配置'
                      : '已配置 ${s.vlessLinks.length} 条 · 取第一条可解析',
                  onTap: () => _openGroup(context, _Group.lines),
                ),
                _row(
                  theme,
                  icon: Icons.layers_outlined,
                  title: 'proxyip',
                  value: '${s.proxyIps.length} 条 · 替换回源 ip:port',
                  onTap: () => _openGroup(context, _Group.lines),
                  last: true,
                ),
              ]),
              _sectionHeader(theme, '测速'),
              _card([
                _row(
                  theme,
                  icon: Icons.speed_outlined,
                  title: '并发',
                  value: '指纹 ${s.sha1Concurrency} · 延迟 ${s.latencyConcurrency}'
                      ' · 速度 ${s.speedConcurrency}',
                  onTap: () => _openGroup(context, _Group.concurrency),
                ),
                _row(
                  theme,
                  icon: Icons.timer_outlined,
                  title: '超时',
                  value: '连接 ${s.dialTimeout}s · 下载 ${s.downloadTimeout}s',
                  onTap: () => _openGroup(context, _Group.timeouts),
                ),
                _row(
                  theme,
                  icon: Icons.network_ping,
                  title: '延迟测试地址',
                  value: s.latencyUrl.isEmpty ? '未配置' : s.latencyUrl,
                  onTap: () => _openGroup(context, _Group.latencyUrl),
                ),
                _row(
                  theme,
                  icon: Icons.download_outlined,
                  title: '速度测试地址',
                  value: s.speedUrl.isEmpty ? '未配置' : s.speedUrl,
                  onTap: () => _openGroup(context, _Group.speedUrl),
                  last: true,
                ),
              ]),
              _sectionHeader(theme, '推送与远程'),
              _card([
                _row(
                  theme,
                  icon: Icons.cloud_upload_outlined,
                  title: 'GitHub 推送',
                  value: s.githubRepo.isEmpty ? '未配置仓库' : s.githubRepo,
                  onTap: () => _openGroup(context, _Group.github),
                ),
                _row(
                  theme,
                  icon: Icons.dns_outlined,
                  title: '远程执行',
                  value: s.remoteHost.isEmpty
                      ? '未配置服务器'
                      : '${s.remoteUser}@${s.remoteHost}:${s.remotePort}',
                  onTap: () => _openGroup(context, _Group.remote),
                  last: true,
                ),
              ]),
              const SizedBox(height: 10),
              Center(
                child: Text(
                  '参数保存在本机，下次启动自动恢复',
                  style: theme.textTheme.labelSmall,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _saveBar(theme),
    );
  }

  // ---------------------------------------------------------------- 分组弹层

  Future<void> _openGroup(BuildContext context, _Group group) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _GroupSheet(
        title: group.title,
        subtitle: group.hint,
        children: _fieldsFor(group),
      ),
    );
    if (mounted) setState(() {});
  }

  List<Widget> _fieldsFor(_Group g) {
    switch (g) {
      case _Group.lines:
        return [
          _multiline('VLESS 链接', _vless,
              hint: 'vless://uuid@host:443?type=xhttp&security=tls&...'),
          _caption('每行一条，取第一条可解析的'),
          const SizedBox(height: 10),
          _proxyIpsActions(),
          _caption('从文件加载，不在此展示内容；使用时自动替换 VLESS 路径里的回源 ip:port。'),
        ];
      case _Group.concurrency:
        return [
          _num('指纹筛选并发', _sha1, hint: '默认 30'),
          _num('延迟测试并发', _latency, hint: '默认 100'),
          _num('速度测试并发', _speed, hint: '默认 3，建议 3-6'),
          // 阈值只用来省测速时间，不负责判定可用。
          _num(
            '延迟上限（ms）',
            _maxLatency,
            hint: '0 = 不限（推荐）',
            helper: '只用于「一键测试」时跳过太慢的候选以节省测速时间，'
                '不代表节点不可用；「延迟测试」不受此项影响。',
          ),
        ];
      case _Group.timeouts:
        return [
          _num('连接超时（秒）', _dial, hint: '默认 5'),
          _num('下载超时（秒）', _download, hint: '默认 10'),
        ];
      case _Group.latencyUrl:
        return [
          _text('延迟测试地址', _latencyUrl, hint: Defaults.latencyUrl),
          _caption('延迟只测「一段往返」（TTFB），要求小端点、无 body、无跳转；'
              '留空或不可达时自动尝试内置候选（cp.cloudflare.com / gstatic）。'
              '别把它指向大文件或会 302 的地址，读数会比 v2rayN 大一倍以上。'),
        ];
      case _Group.speedUrl:
        return [
          _text('速度测试地址', _speedUrl, hint: Defaults.speedUrl),
          _caption('窗口 3s / 上限 64MiB，首 256KiB 预热丢弃。'
              '必须是能持续吐数据的大文件，小端点（204）测不出速度。'),
        ];
      case _Group.github:
        return [
          _text('仓库地址', _ghRepo, hint: 'https://github.com/0-RTT/sub'),
          _text('Token', _ghToken, obscure: true, hint: '需要 repo contents 写权限'),
        ];
      case _Group.remote:
        return [
          _text('主机', _remoteHost, hint: '1.2.3.4'),
          _num('端口', _remotePort, hint: '默认 22'),
          _text('用户', _remoteUser, hint: '默认 root'),
          _text('密码', _remotePassword, obscure: true),
          _text('私钥路径', _remoteKey, hint: '留空则用密码'),
        ];
    }
  }

  // ------------------------------------------------------------------ 构件

  Widget _sectionHeader(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
        child: Text(
          text,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );

  /// 分组卡：玻璃材质。列表页会滚动，不开实时模糊，
  /// 半透明填充在渐变底上已经足够「玻璃」。
  Widget _card(List<Widget> rows) => GlassCard(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Glass.cardRadius - 1),
          child: Column(children: rows),
        ),
      );

  Widget _row(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
    bool last = false,
  }) {
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
            child: Row(
              children: [
                Icon(icon, size: 21, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 20, color: theme.colorScheme.outline),
              ],
            ),
          ),
          if (!last)
            Divider(
              height: 0.5,
              thickness: 0.5,
              indent: 47,
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
        ],
      ),
    );
  }

  Widget _saveBar(ThemeData theme) => GlassBar(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: SizedBox(
            height: 46,
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('保存'),
            ),
          ),
        ),
      );

  List<String> _lines(String text) =>
      text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  Widget _proxyIpsActions() {
    final count = context.watch<AppState>().settings.proxyIps.length;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: (_theme ?? ThemeData.light()).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            'proxyip $count 条',
            style: (_theme ?? ThemeData.light()).textTheme.labelSmall?.copyWith(
                  color: (_theme ?? ThemeData.light())
                      .colorScheme
                      .onSecondaryContainer,
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
  }

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

  Widget _caption(String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          text,
          style: _theme?.textTheme.labelSmall
              ?.copyWith(color: _theme!.colorScheme.onSurfaceVariant),
        ),
      );

  InputDecoration _decoration({
    required String label,
    String? hint,
    String? helper,
  }) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 2,
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

  Widget _num(
    String label,
    TextEditingController c, {
    String? hint,
    String? helper,
  }) =>
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          decoration: _decoration(label: label, hint: hint, helper: helper),
        ),
      );

  Widget _text(String label, TextEditingController c,
          {String? hint, bool obscure = false}) =>
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: TextField(
          controller: c,
          obscureText: obscure,
          style: const TextStyle(fontSize: 13),
          decoration: _decoration(label: label, hint: hint),
        ),
      );

  Widget _multiline(String label, TextEditingController c, {String? hint}) =>
      Padding(
        padding: const EdgeInsets.only(top: 10),
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

/// 设置页的分组。每个分组对应一个底部弹层。
enum _Group {
  lines('线路与代理', '抓取与测速的出入口'),
  concurrency('并发', '过高会互相抢带宽，单条读数偏低'),
  timeouts('超时', '网络抖动大时适当放宽'),
  latencyUrl('延迟测试地址', 'TTFB 口径：小端点、无 body、不跟随跳转'),
  speedUrl('速度测试地址', '窗口 3s / 上限 64MiB，首 256KiB 预热丢弃'),
  github('GitHub 推送', '把订阅写到仓库文件'),
  remote('远程执行', 'SSH 到服务器跑三阶段');

  const _Group(this.title, this.hint);

  final String title;
  final String hint;
}

/// 分组编辑弹层：标题 + 说明 + 字段列表，字段直接绑定根页面的 controller，
/// 关掉弹层后由根页面 setState 刷新摘要。
class _GroupSheet extends StatelessWidget {
  const _GroupSheet({
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            ...children,
            const SizedBox(height: 14),
            SizedBox(
              height: 44,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('完成'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
