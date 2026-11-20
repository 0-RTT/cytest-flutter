import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/file_pick.dart';
import '../../core/settings.dart';
import '../../data/github.dart';
import '../../state/app_state.dart';
import '../widgets/glass.dart';

/// 设置页：参考系统「更多」页的分组列表形态。
///
/// 版式约定：
/// - 页面底是浅灰；每个分组 = 一行灰色小标题 + 一张白色圆角卡片；
/// - 卡片里每行 = 图标 + 标题 + 当前值（副标题）+ 右箭头，行间用内缩细分割线；
/// - 点行进入底部弹层编辑该组字段，根页面只保留摘要，长表单不再把首页拉得很长；
/// - 改动**自动保存**（见 [_SettingsPageState._onFieldChanged]），底部按钮是「立刻保存」。
///
/// 三条硬规则（都是踩过的坑，改动时不要退化）：
/// 1. **绑定时序**：`AppState` 的 `boot()` 是异步的、UI 不等它，页面必须在读到
///    磁盘设置之后再同步一次（[_SettingsPageState._onStateChanged]），否则表单里
///    留着一整屏默认值。
/// 2. **只写脏字段**：保存只提交「与快照不同」的字段，没编辑过的一律保持
///    `settings` 里的现值 —— 这是防止「一个字段的改动抹掉其余配置」的护栏。
/// 3. **保存必须可见**：落盘失败、读写不一致都要提示 + 写日志，不许静默。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _formKey = GlobalKey<FormState>();

  late AppState _state;

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
  late TextEditingController _subPath;
  late TextEditingController _yamlPath;
  late TextEditingController _remoteHost;
  late TextEditingController _remotePort;
  late TextEditingController _remoteUser;
  late TextEditingController _remotePassword;
  late TextEditingController _remoteKey;
  late TextEditingController _vless;

  /// 表单原值快照：绑定时记一份，每次保存成功后刷新。
  ///
  /// 它的唯一用途是算「脏字段」= 表单现值 vs 快照。没有它就回到了旧实现那种
  /// 「16 个 controller 全量写回」——一个过期的默认值就能覆盖掉磁盘上的配置。
  _FormValues? _snapshot;

  /// 是否已经跟「磁盘上读到的设置」同步过一次（boot 完成后的那一次）。
  bool _syncedWithDisk = false;

  /// 程序化改写 controller 时置位，避免自己触发自动保存（否则会自激循环）。
  bool _suppress = false;

  /// 文本字段的自动保存去抖器。
  Timer? _debounce;

  /// 保存队列：所有保存串行执行。
  ///
  /// 为什么必须串行：`SharedPreferences.setString` 是「整份 JSON 覆盖写」，
  /// 两次保存并发时后完成的赢，先完成的那次改动就丢了。串行之后再慢也只是排队。
  Future<void> _saveQueue = Future<void>.value();

  /// 退到后台时抢救一次未落盘的改动（Android 上用户常直接从最近任务划掉）。
  AppLifecycleListener? _lifecycle;

  /// 底部状态栏文案（「已自动保存」/ 失败原因）。
  String _statusText = '';
  bool _statusIsError = false;

  ThemeData? _theme;

  /// 停止输入多久后自动保存。
  static const _autosaveDebounce = Duration(milliseconds: 600);

  /// 需要「归一化回填」的字段：空地址 → 默认地址、仓库链接 → owner/repo。
  ///
  /// 只有这三个字段存在「输入值 ≠ 落库值」的情况，其余字段的值本来就一一对应。
  static const Set<_Field> _normalizedFields = <_Field>{
    _Field.speedUrl,
    _Field.latencyUrl,
    _Field.githubRepo,
  };

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>();
    // 先把「当前内存里的 settings」绑进表单。boot 还没结束时这份是默认值，
    // 这不重要 —— 读完盘后 _onStateChanged 会重新同步（只补没被编辑的字段）。
    _bind(_state.settings);
    // boot 已经结束（例如热重载、或 boot 在页面挂载前就完成了）= 已经是最新的。
    _syncedWithDisk = !_state.booting;
    _state.addListener(_onStateChanged);
    _lifecycle = AppLifecycleListener(
      onHide: _flushPending,
      onPause: _flushPending,
    );
  }

  /// 建立 16 个 controller 并记下快照。
  void _bind(AppSettings s) {
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
    _subPath = TextEditingController(text: s.subPath);
    _yamlPath = TextEditingController(text: s.yamlPath);
    _remoteHost = TextEditingController(text: s.remoteHost);
    _remotePort = TextEditingController(text: '${s.remotePort}');
    _remoteUser = TextEditingController(text: s.remoteUser);
    _remotePassword = TextEditingController(text: s.remotePassword);
    _remoteKey = TextEditingController(text: s.remoteKeyPath);
    _vless = TextEditingController(text: s.vlessLinks.join('\n'));
    for (final c in _controllers) {
      c.addListener(_onFieldChanged);
    }
    _snapshot = _FormValues.fromSettings(s);
  }

  List<TextEditingController> get _controllers => <TextEditingController>[
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
        _subPath,
        _yamlPath,
        _remoteHost,
        _remotePort,
        _remoteUser,
        _remotePassword,
        _remoteKey,
        _vless,
      ];

  @override
  void dispose() {
    _debounce?.cancel();
    _debounce = null;
    // 页面被销毁（路由化改造、测试换树）时抢救一次未落盘的改动。
    // 必须**先同步读**成值快照：dispose 之后 controller 就不可用了。
    if (_dirtyFields().isNotEmpty) {
      final form = _readForm();
      unawaited(_save(quiet: true, captured: form));
    }
    _lifecycle?.dispose();
    _lifecycle = null;
    _state.removeListener(_onStateChanged);
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------- 绑定 / 脏字段计算

  /// boot 结束（`settings` 换成磁盘上的真实配置）后的那次同步。
  ///
  /// 为什么要在监听里做而不是只靠 initState：`main.dart` 是 `AppState()..boot()`，
  /// boot 是异步的，页面几乎总是在「settings 还是默认值」时就挂载完成了；
  /// 只在 initState 绑一次，表单里就永远是一屏默认值。
  void _onStateChanged() {
    if (_syncedWithDisk) return;
    if (_state.booting) return; // 还没读完盘，等下一次通知
    _syncedWithDisk = true;
    if (!mounted) return;
    setState(() => _syncFromLoaded(_state.settings));
  }

  /// 把「磁盘上读到的设置」补进表单，但**绝不覆盖用户已经改过的字段**。
  ///
  /// 为什么不能整屏覆盖：用户在 boot 完成的瞬间可能正在输入（比如粘贴一条
  /// 链接），整屏覆盖会把刚输入的内容冲掉；而只补未编辑字段既能纠正「默认值
  /// 占位」的问题，又不会碰到用户的手指。
  void _syncFromLoaded(AppSettings s) {
    final loaded = _FormValues.fromSettings(s);
    final edited = _diff(_readForm(), _snapshot ?? loaded);
    _suppress = true;
    try {
      for (final field in _Field.values) {
        if (edited.contains(field)) continue; // 用户的手比 boot 快：不碰
        final controller = _controllerOf(field);
        final text = _textOf(_valueOf(loaded, field));
        if (controller.text != text) controller.text = text;
      }
    } finally {
      _suppress = false;
    }
    // 快照换成磁盘上的值：此后「脏」的判定基准就是真实配置。
    _snapshot = loaded;
    _statusText = edited.isEmpty
        ? '已读取本机保存的设置'
        : '已读取本机保存的设置（保留了你正在编辑的 ${edited.length} 项）';
    _statusIsError = false;
  }

  /// 表单现值（已归一化）。`_snapshot` 提供数值解析失败时的兜底。
  _FormValues _readForm() {
    final base = _snapshot ?? _FormValues.fromSettings(_state.settings);
    int intOf(TextEditingController c, int fallback) =>
        int.tryParse(c.text.trim()) ?? fallback;
    // 两个地址的空串语义都是「恢复默认」（不是「关闭这一档」）：
    // 空地址会让延迟探测报「地址非法」、让三阶段下载报配置错误。
    // 这条语义是原有约定，改 dirty 逻辑时不能弄丢。
    final speed = _speedUrl.text.trim();
    final latency = _latencyUrl.text.trim();
    final repoInput = _ghRepo.text.trim();
    return _FormValues(
      sha1Concurrency: intOf(_sha1, base.sha1Concurrency),
      latencyConcurrency: intOf(_latency, base.latencyConcurrency),
      speedConcurrency: intOf(_speed, base.speedConcurrency),
      maxLatency: intOf(_maxLatency, base.maxLatency),
      dialTimeout: intOf(_dial, base.dialTimeout),
      downloadTimeout: intOf(_download, base.downloadTimeout),
      speedUrl: speed.isEmpty ? Defaults.speedUrl : speed,
      latencyUrl: latency.isEmpty ? Defaults.latencyUrl : latency,
      // 仓库地址允许直接粘网页链接，统一规范化成 owner/repo。
      githubRepo: repoInput.isEmpty ? '' : parseRepoSlug(repoInput),
      githubToken: _ghToken.text.trim(),
      // 文件名同样走「空串=默认」：空文件名会把订阅写到仓库根目录。
      subPath: _subPath.text.trim().isEmpty ? Defaults.subPath : _subPath.text.trim(),
      yamlPath: _yamlPath.text.trim().isEmpty ? Defaults.yamlPath : _yamlPath.text.trim(),
      remoteHost: _remoteHost.text.trim(),
      remotePort: intOf(_remotePort, base.remotePort),
      remoteUser: _remoteUser.text.trim(),
      remotePassword: _remotePassword.text,
      remoteKeyPath: _remoteKey.text.trim(),
      vlessLinks: _lines(_vless.text),
    );
  }

  Set<_Field> _dirtyFields() {
    final base = _snapshot;
    if (base == null) return const <_Field>{};
    return _diff(_readForm(), base);
  }

  /// 逐字段比对，得到「表单里被改过」的字段集合。
  ///
  /// **驱动源是 `_Field.values`**，单个字段的比较落在 [_valueOf]（穷尽 switch
  /// 表达式）里 —— 新增字段时少写一处就是**编译错误**，不会出现「这个字段
  /// 永远不保存但零报错」的静默漏写（这正是 R2）。
  Set<_Field> _diff(_FormValues form, _FormValues base) {
    final out = <_Field>{};
    for (final field in _Field.values) {
      if (!_sameValue(_valueOf(form, field), _valueOf(base, field))) {
        out.add(field);
      }
    }
    return out;
  }

  /// 同一字段在两份值里的取值（穷尽 switch 表达式：少一个 case 编译失败）。
  ///
  /// `vlessLinks` 返回 `List<String>`，比较要经过 [_sameValue]（列表比内容）。
  Object? _valueOf(_FormValues v, _Field field) => switch (field) {
        _Field.sha1Concurrency => v.sha1Concurrency,
        _Field.latencyConcurrency => v.latencyConcurrency,
        _Field.speedConcurrency => v.speedConcurrency,
        _Field.maxLatency => v.maxLatency,
        _Field.dialTimeout => v.dialTimeout,
        _Field.downloadTimeout => v.downloadTimeout,
        _Field.speedUrl => v.speedUrl,
        _Field.latencyUrl => v.latencyUrl,
        _Field.githubRepo => v.githubRepo,
        _Field.githubToken => v.githubToken,
        _Field.subPath => v.subPath,
        _Field.yamlPath => v.yamlPath,
        _Field.remoteHost => v.remoteHost,
        _Field.remotePort => v.remotePort,
        _Field.remoteUser => v.remoteUser,
        _Field.remotePassword => v.remotePassword,
        _Field.remoteKeyPath => v.remoteKeyPath,
        _Field.vlessLinks => v.vlessLinks,
      };

  /// 字段 → 输入框（穷尽 switch 表达式：少一个 case 编译失败）。
  TextEditingController _controllerOf(_Field field) => switch (field) {
        _Field.sha1Concurrency => _sha1,
        _Field.latencyConcurrency => _latency,
        _Field.speedConcurrency => _speed,
        _Field.maxLatency => _maxLatency,
        _Field.dialTimeout => _dial,
        _Field.downloadTimeout => _download,
        _Field.speedUrl => _speedUrl,
        _Field.latencyUrl => _latencyUrl,
        _Field.githubRepo => _ghRepo,
        _Field.githubToken => _ghToken,
        _Field.subPath => _subPath,
        _Field.yamlPath => _yamlPath,
        _Field.remoteHost => _remoteHost,
        _Field.remotePort => _remotePort,
        _Field.remoteUser => _remoteUser,
        _Field.remotePassword => _remotePassword,
        _Field.remoteKeyPath => _remoteKey,
        _Field.vlessLinks => _vless,
      };

  /// 字段 → 给用户看的名字（失败/自检文案里用）。
  String _labelOf(_Field field) => switch (field) {
        _Field.sha1Concurrency => '指纹并发',
        _Field.latencyConcurrency => '延迟并发',
        _Field.speedConcurrency => '速度并发',
        _Field.maxLatency => '延迟上限',
        _Field.dialTimeout => '连接超时',
        _Field.downloadTimeout => '下载超时',
        _Field.speedUrl => '速度地址',
        _Field.latencyUrl => '延迟地址',
        _Field.githubRepo => 'GitHub 仓库',
        _Field.githubToken => 'GitHub Token',
        _Field.subPath => '订阅文件名',
        _Field.yamlPath => 'YAML 文件名',
        _Field.remoteHost => '远程主机',
        _Field.remotePort => '远程端口',
        _Field.remoteUser => '远程用户',
        _Field.remotePassword => '远程密码',
        _Field.remoteKeyPath => '私钥路径',
        _Field.vlessLinks => 'VLESS 链接',
      };

  /// 取值 → 输入框文本（列表用换行拼）。
  String _textOf(Object? value) =>
      value is List ? value.join('\n') : '${value ?? ''}';

  /// 两个字段值是否等价：列表比内容，其余用 `==`（int/String/bool 都够用）。
  bool _sameValue(Object? a, Object? b) {
    if (a is List<String> && b is List<String>) return listEquals(a, b);
    return a == b;
  }

  /// 把**单个**脏字段写进 settings（未编辑的字段一概不碰）。
  void _applyField(AppSettings s, _Field field, _FormValues v) {
    switch (field) {
      case _Field.sha1Concurrency:
        s.sha1Concurrency = v.sha1Concurrency;
      case _Field.latencyConcurrency:
        s.latencyConcurrency = v.latencyConcurrency;
      case _Field.speedConcurrency:
        s.speedConcurrency = v.speedConcurrency;
      case _Field.maxLatency:
        s.maxLatency = v.maxLatency;
      case _Field.dialTimeout:
        s.dialTimeout = v.dialTimeout;
      case _Field.downloadTimeout:
        s.downloadTimeout = v.downloadTimeout;
      case _Field.speedUrl:
        s.speedUrl = v.speedUrl;
      case _Field.latencyUrl:
        s.latencyUrl = v.latencyUrl;
      case _Field.githubRepo:
        s.githubRepo = v.githubRepo;
      case _Field.githubToken:
        s.githubToken = v.githubToken;
      case _Field.subPath:
        s.subPath = v.subPath;
      case _Field.yamlPath:
        s.yamlPath = v.yamlPath;
      case _Field.remoteHost:
        s.remoteHost = v.remoteHost;
      case _Field.remotePort:
        s.remotePort = v.remotePort;
      case _Field.remoteUser:
        s.remoteUser = v.remoteUser;
      case _Field.remotePassword:
        s.remotePassword = v.remotePassword;
      case _Field.remoteKeyPath:
        s.remoteKeyPath = v.remoteKeyPath;
      case _Field.vlessLinks:
        s.vlessLinks = List<String>.of(v.vlessLinks);
    }
  }

  // ------------------------------------------------------------- 自动保存

  /// 任一字段变化：立刻刷新状态文案，并起一个 600ms 的去抖定时器。
  ///
  /// 为什么用去抖而不是每次按键都写：文本字段逐字符保存会把
  /// `SharedPreferences` 写成 IO 风暴（一次保存 = 一整份 JSON 覆盖写）；
  /// 600ms 是「打字停顿」与「切走就丢」之间的折中。开关/单选类改动本身就该
  /// 立即生效，本页现有控件里没有这类字段（proxyip 的导入/清空走
  /// [AppState.importProxyIps] 等自有持久化），因此只需覆盖文本字段。
  void _onFieldChanged() {
    if (_suppress) return;
    _debounce?.cancel();
    _debounce = Timer(_autosaveDebounce, () {
      _debounce = null;
      unawaited(_save(quiet: true));
    });
    if (!mounted) return;
    final dirty = _dirtyFields();
    setState(() {
      _statusText = dirty.isEmpty ? '' : '有未保存的改动，正在自动保存…';
      _statusIsError = false;
    });
  }

  /// 退到后台 / 页面消失时把待保存的改动立刻提交。
  void _flushPending() {
    _debounce?.cancel();
    _debounce = null;
    if (_dirtyFields().isEmpty) return;
    unawaited(_save(quiet: true));
  }

  /// 入队一次保存。**所有**保存路径都走这里，保证串行。
  Future<void> _save({required bool quiet, _FormValues? captured}) {
    _debounce?.cancel();
    _debounce = null;
    final job = _saveQueue.then((_) async {
      try {
        await _saveNow(quiet: quiet, captured: captured);
      } on Object catch (e) {
        // 队列里不能被异常打断：一旦 reject，后面所有自动保存都会跳过。
        _reportError('保存失败：$e');
      }
    });
    _saveQueue = job;
    return job;
  }

  Future<void> _saveNow({required bool quiet, _FormValues? captured}) async {
    final base = _snapshot ?? _FormValues.fromSettings(_state.settings);
    final form = captured ?? _readForm();
    final dirty = _diff(form, base);

    // 仓库地址还没输完（自动保存时很常见）：既不落库也不弹提示，
    // 只在状态栏说一声；点「保存」才告诉用户格式该怎么改。
    final repoError = _validateRepo();
    if (repoError != null) {
      if (quiet) {
        _setStatus('仓库地址还没输完，暂不自动保存', error: true);
      } else {
        _showSnack(repoError);
      }
      return;
    }

    // 归一化回填（空地址 → 默认、repo → owner/repo）。
    // 只在手动保存时回填：自动保存时回填会把用户正在输入的光标位置打乱。
    //
    // 为什么放在 dirty 判定**之前**：自动保存可能已经把值写进去了
    // （例如用户粘贴整条仓库链接、去抖先存成 owner/repo），此时 dirty 为空，
    // 但输入框里还是一整条链接 —— 用户点了「保存」就该看到真正生效的
    // owner/repo，而不是「没保存」的假象。
    if (!quiet) _backfillNormalized(form);

    if (dirty.isEmpty) {
      if (!quiet) {
        _snapshot = form;
        _setStatus('没有需要保存的改动');
        _showSnack('设置已保存');
      }
      return;
    }

    // 乐观写入：先把脏字段灌进内存的 settings，用户立刻看到摘要变化。
    //
    // 但**快照不能在这里推进**（R1）：`_snapshot` 是「脏」的基准线，一旦在落盘
    // 之前推进，写盘失败后 `_dirtyFields()` 就变空 —— 用户再点「保存」只会得到
    // 「没有需要保存的改动」，一次写盘都不发；`dispose` 里的抢救同样被判成
    // 「没东西要存」。表现就是用户说的「我明明保存了，重启后配置却丢了」。
    // 所以快照只在「写盘成功 + 回读校验通过」之后才推进（见方法末尾）。
    final s = _state.settings;
    for (final field in dirty) {
      _applyField(s, field, form);
    }
    _state.notifySettingsChanged(); // 摘要先跟着动（乐观）

    _setStatus('正在保存…');
    try {
      await _state.saveSettings();
    } on Object catch (e) {
      // 两条善后都必须做：
      // 1) **回滚**乐观写入 —— 否则界面显示新值、磁盘还是旧值，用户以为存上了；
      // 2) **不推进快照** —— 脏字段仍在，下一次保存 / 关弹层 / 退后台 / dispose
      //    都会重新提交，用户不用重启重填。
      _rollback(dirty, base);
      _reportError('保存失败：$e（改动没丢，再点「保存」会重试）');
      return;
    }

    final mismatch = await _verifyOnDisk();
    if (mismatch != null) {
      // 自检不过 = 没存住，走**同一条**失败路径：回滚 + 不推进快照 + 可重试。
      _rollback(dirty, base);
      _reportError('已写入，但重新读取时对不上：$mismatch（再点「保存」会重试）');
      return;
    }

    // 到这里才算真的存住了：快照推进到本次表单值，脏字段归零。
    _snapshot = form;
    _setStatus(quiet ? '已自动保存' : '设置已保存');
    if (!quiet) _showSnack('设置已保存');
  }

  /// 把乐观写进内存的那批字段退回快照里的值（= 上一次确认存活的值）。
  ///
  /// 只回滚本次真正动过的字段：其它字段可能是别处（如 proxyip 导入）刚改的，
  /// 一律拿快照覆盖会把别人的改动一起抹掉。
  void _rollback(Set<_Field> dirty, _FormValues base) {
    final s = _state.settings;
    for (final field in dirty) {
      _applyField(s, field, base);
    }
    _state.notifySettingsChanged();
  }

  /// 把归一化后的值写回输入框（空地址变默认地址、仓库变 owner/repo）。
  ///
  /// 只回填「会被归一化」的三个字段：数字字段若原样换成解析后的值，用户输入到
  /// 一半（比如刚打了个「-」）就会被改写，得不偿失。
  void _backfillNormalized(_FormValues form) {
    _suppress = true;
    try {
      for (final field in _normalizedFields) {
        final controller = _controllerOf(field);
        final text = _textOf(_valueOf(form, field));
        if (controller.text != text) controller.text = text;
      }
    } finally {
      _suppress = false;
    }
  }

  /// 落盘自检：写完立刻读回来比一遍。
  ///
  /// 为什么值得多读一次：真机上出现过「`setString` 返回成功、重启后配置没了」
  /// 的插件级问题。只信返回值等于把用户配置交给一条没有校验的通道；这里读
  /// 回来比对，一旦不一致就当场告警而不是等用户下次启动才发现。
  ///
  /// **16 个字段全比**（R4）：只比 8 个的话，Token / 远程密码 / 端口 / 私钥路径 /
  /// VLESS 链接 / 两个超时的静默丢写完全抓不到 —— 而「静默丢写」正是这类
  /// 插件级故障的典型表现。字段表来自 `_Field.values`，新增字段自动纳入。
  Future<String?> _verifyOnDisk() async {
    final AppSettings disk;
    try {
      disk = await AppSettings.load();
    } on Object catch (e) {
      return '重新读取失败（$e）';
    }
    final expected = _FormValues.fromSettings(_state.settings);
    final actual = _FormValues.fromSettings(disk);
    final bad = <String>[
      for (final field in _Field.values)
        if (!_sameValue(_valueOf(expected, field), _valueOf(actual, field)))
          '${_labelOf(field)}=${_textOf(_valueOf(actual, field)).replaceAll('\n', ' ')}',
    ];
    if (bad.isEmpty) return null;
    return '磁盘上${bad.join('、')}';
  }

  /// 仓库地址格式校验（空串 = 不配置 GitHub，合法）。
  String? _validateRepo() {
    final input = _ghRepo.text.trim();
    if (input.isEmpty) return null;
    if (parseRepoSlug(input).isEmpty) {
      return '仓库地址格式不对，应形如 https://github.com/owner/repo';
    }
    return null;
  }

  void _setStatus(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _statusText = text;
      _statusIsError = error;
    });
  }

  /// 失败必须同时进 UI 和日志：日志是「用户报‘保存没反应’」时唯一能查的东西。
  void _reportError(String message) {
    _state.pushLog(message);
    if (!mounted) return;
    setState(() {
      _statusText = message;
      _statusIsError = true;
    });
    _showSnack(message);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _theme = theme;
    final state = context.watch<AppState>();
    final s = state.settings;

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
              if (state.booting) _bootingNotice(theme),
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
                  '改动会自动保存到本机（停止输入约 0.6 秒后），下次启动自动恢复',
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

  /// 读盘还没结束时给一句明确的交代。
  ///
  /// 为什么不禁用编辑：boot 通常只花几十毫秒，锁住输入反而让人以为页面卡住；
  /// 真正的护栏是「只写脏字段 + 只同步未编辑字段」，用户此刻输入什么都不会
  /// 被读盘结果覆盖，也不会被写回成默认值。
  Widget _bootingNotice(ThemeData theme) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: GlassCard(
          shadow: false,
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Row(
            children: [
              Icon(Icons.hourglass_empty,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '正在读取本机保存的设置…读完会自动同步；你已经改过的项不会被覆盖。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      );

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
    if (!mounted) return;
    // 关掉弹层就是一次「编辑结束」：立刻保存，不等 600ms 去抖。
    // 用户点「完成」往往紧接着切 Tab / 退到后台，这里顺手提交最稳。
    _flushPending();
    setState(() {});
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
          _text('订阅文件名（base64）', _subPath, hint: Defaults.subPath),
          _text('mihomo 文件名（YAML）', _yamlPath, hint: Defaults.yamlPath),
          _caption('推送时写到仓库的这两个文件；留空则用默认名。'),
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

  /// 底部操作条：左边是保存状态（失败时红字），右边是「立刻保存」。
  ///
  /// 保留按钮是必要的：自动保存是兜底，用户按下去的那一刻要能立刻确认结果。
  Widget _saveBar(ThemeData theme) => GlassBar(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _statusText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _statusIsError
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 148,
                height: 46,
                child: FilledButton.icon(
                  onPressed: () => unawaited(_save(quiet: false)),
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('保存'),
                ),
              ),
            ],
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

/// 表单里可编辑的 16 个字段。
///
/// 为什么用枚举而不是字符串：[_SettingsPageState._applyField] 的 `switch` 是
/// 穷尽的 —— 将来 `AppSettings` 加字段、这里漏加，编译器会报「switch 不完整」，
/// 而不是静默漏存。
enum _Field {
  sha1Concurrency,
  latencyConcurrency,
  speedConcurrency,
  maxLatency,
  dialTimeout,
  downloadTimeout,
  speedUrl,
  latencyUrl,
  githubRepo,
  githubToken,
  subPath,
  yamlPath,
  remoteHost,
  remotePort,
  remoteUser,
  remotePassword,
  remoteKeyPath,
  vlessLinks,
}

/// 表单的一份值快照（不可变、已归一化）。
///
/// 只包含「表单里能改」的字段：`fingerprint` / `httpProxy` / `fetchProxy` /
/// `proxyIps` 不在表单里，也就不参与 dirty 判定 —— 它们永远由各自的入口维护，
/// 保存时不会被表单的空值顺手抹掉。
@immutable
class _FormValues {
  const _FormValues({
    required this.sha1Concurrency,
    required this.latencyConcurrency,
    required this.speedConcurrency,
    required this.maxLatency,
    required this.dialTimeout,
    required this.downloadTimeout,
    required this.speedUrl,
    required this.latencyUrl,
    required this.githubRepo,
    required this.githubToken,
    required this.subPath,
    required this.yamlPath,
    required this.remoteHost,
    required this.remotePort,
    required this.remoteUser,
    required this.remotePassword,
    required this.remoteKeyPath,
    required this.vlessLinks,
  });

  factory _FormValues.fromSettings(AppSettings s) => _FormValues(
        sha1Concurrency: s.sha1Concurrency,
        latencyConcurrency: s.latencyConcurrency,
        speedConcurrency: s.speedConcurrency,
        maxLatency: s.maxLatency,
        dialTimeout: s.dialTimeout,
        downloadTimeout: s.downloadTimeout,
        speedUrl: s.speedUrl,
        latencyUrl: s.latencyUrl,
        githubRepo: s.githubRepo,
        githubToken: s.githubToken,
        subPath: s.subPath,
        yamlPath: s.yamlPath,
        remoteHost: s.remoteHost,
        remotePort: s.remotePort,
        remoteUser: s.remoteUser,
        remotePassword: s.remotePassword,
        remoteKeyPath: s.remoteKeyPath,
        vlessLinks: List<String>.unmodifiable(s.vlessLinks),
      );

  final int sha1Concurrency;
  final int latencyConcurrency;
  final int speedConcurrency;
  final int maxLatency;
  final int dialTimeout;
  final int downloadTimeout;
  final String speedUrl;
  final String latencyUrl;
  final String githubRepo;
  final String githubToken;
  final String subPath;
  final String yamlPath;
  final String remoteHost;
  final int remotePort;
  final String remoteUser;
  final String remotePassword;
  final String remoteKeyPath;
  final List<String> vlessLinks;
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
