import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/bin.dart';
import '../core/paths.dart';
import '../core/settings.dart';
import '../data/history.dart';
import '../data/link_test.dart';
import '../data/link_test_store.dart';
import '../data/pipeline.dart';
import '../data/proxy_ip_csv.dart';
import '../data/vless.dart';
import '../data/xray.dart';

/// 全局状态：设置、线路、测试运行、结果。与 Android 端 TestViewModel 的职责对齐。
class AppState extends ChangeNotifier {
  /// [runner] 仅供单测注入（默认按真实 [xray] + 真实落盘构造）。
  ///
  /// 之所以留这个口子：`runLinkTest` 的「防重入」必须能被单测断言
  /// （第二次调用不能清掉第一轮的进度、不能把「在跑」标成「没跑」），
  /// 而真跑一轮测速需要 xray 二进制 —— 不注入就永远验不了。
  AppState({XrayProc? xray, LinkTestRunner? runner})
      : xray = xray ?? XrayProc() {
    // onLog 走 pushLog：测试页的「测速日志」面板就是 state.logs，于是
    // 「建连/响应头/首字节」分项计时对用户和排障者都直接可见。
    linkTestRunner = runner ??
        LinkTestRunner(
          xray: this.xray,
          saver: LinkTestStore().save,
          onLog: pushLog,
        );
    // 注入 runner 的那条路上构造参数里的 onLog 不会执行，这里补接一次
    // （已有 sink 时 ensureLogSink 不会覆盖，尊重调用方显式注入的出口）。
    // 少了这一行，任何用 `AppState(runner: ...)` 的地方都会静默丢掉测速日志，
    // 表现就是「测速日志面板一片空白」。
    linkTestRunner.ensureLogSink(pushLog);
  }

  AppSettings settings = AppSettings();
  final XrayProc xray;

  /// 链路测速编排器。
  late final LinkTestRunner linkTestRunner;

  List<Map<String, String>> rows = const [];
  Directory? lastRunDir;
  String? lastError;

  final List<String> logs = [];
  bool running = false;
  int progressCur = 0;
  int progressTotal = 0;
  String progressStage = '';

  bool booting = true;
  String binStatus = '';

  /// 当前三阶段运行的取消令牌（null = 没有在跑）。
  ///
  /// 每轮新建：令牌一旦 cancelled 就永久置位，复用会让下一轮刚起进程就被杀掉。
  PipelineCancelToken? _runToken;

  // --- 链路测速（T03） -------------------------------------------------------

  /// 测速进度结果（UI 只读）。
  List<LinkTestResult> linkResults = const [];

  /// 当前阶段文字（「准备中 / 延迟探测 / 速度探测 / 完成 / 已取消」）。
  String linkStage = '';

  /// 是否正在测速。**不要复用它判断「有没有代理」**：代理的唯一真相是
  /// `xray.mode`（`xray.running` 只在 `mode == line` 时为真）。UI 判「测速中」
  /// 请用 `linkTestRunning || xray.mode == XrayMode.batch`。
  bool linkTestRunning = false;

  /// 测速失败的可读原因（null = 没有错误）。
  String? linkTestError;

  /// 链路测速的轮次令牌（每次 [runLinkTest] 自增，见 [_isCurrentLinkRun]）。
  int _linkRunToken = 0;

  /// R12 预留：为什么代理被停了（一次性、读取即消费）。
  ///
  /// **A 方案下不写值**，只为 B/C 方案预留接口。
  /// 禁止用它参与任何判定——代理是否可用只看 `xray.mode`。
  String? proxyStopReason;

  /// 「代理刚被测速停掉」的一次性提示（内部存储，只经 [takeProxyStopNotice] 读取）。
  String? _proxyStopNotice;

  /// 取走提示（**one-shot：读取即置空**）。
  ///
  /// 为什么必须一次性：T04 需要在用户切到「获取数据」时提示「测速已停止代理线路」。
  /// 用持久 bool 存「谁停的代理」会与 `xray.mode` 形成两份事实副本，
  /// 用户改链接/杀进程重进后会永久僵死为 true（两份事实副本必然打架）。
  /// 读完即清 → 提示只出现一次，且永远不会与真实状态打架。
  String? takeProxyStopNotice() {
    final notice = _proxyStopNotice;
    _proxyStopNotice = null;
    return notice;
  }

  /// 仅供单测：直接置位提示，用于验证「读取即消费」不会僵死。
  ///
  /// 生产代码里只有 [runLinkTest] 会写这个字段；加这个方法是为了让 one-shot
  /// 语义有可执行的断言（否则只能靠读代码，等于没验）。
  void debugSetProxyStopNoticeForTest(String? value) {
    _proxyStopNotice = value;
  }

  /// 可用条数。
  int get linkOkCount => linkResults.where((r) => r.ok).length;

  /// 把一条历史测速记录载回当前结果（记录页点进去看/推送用）。
  ///
  /// 只填展示用状态、**不动 runner**：这不是一次新的测速，没有进程要起。
  /// 阶段文字写明「历史记录」，避免用户把它当成刚跑完的结果。
  void loadLinkRun(LinkTestRun run) {
    linkResults = run.results;
    linkStage = '历史记录';
    linkTestError = null;
    notifyListeners();
  }

  /// 最快速度（MiB/s）。
  double get linkFastest {
    var best = 0.0;
    for (final r in linkResults) {
      final speed = r.speedMib ?? 0;
      if (r.hasSpeed && speed > best) best = speed;
    }
    return best;
  }

  Future<void> boot() async {
    // 启动是「必须成功」的路径：任何一步抛异常都不能让 App 停在半初始化状态
    // （过去没有 try/catch，SharedPreferences 异常会让 booting 永远是 true，
    // 界面上没有任何提示，用户只看到「设置没生效」）。
    try {
      settings = await AppSettings.load();
    } catch (e) {
      lastError = '读取设置失败：$e（已使用默认值）';
      pushLog('✗ 读取设置失败：$e');
    } finally {
      // 设置里配的两个端点要真正生效：runner 是构造期建的（那时还没读盘），
      // 所以只能在读完设置之后把地址灌进去。为空串时 runner 自己回落默认值。
      _applyLinkTestUrls();
      booting = false;
      notifyListeners();
    }
    unawaited(_warmBinaries());
    unawaited(_loadProxyIps());
  }

  // --- proxyip 文件（与原版一致：cytest/xray/proxyip.csv） -------------------

  /// proxyip 列表文件的路径。与抓取/推送侧的 `xray/proxyip.csv`
  /// （`filesDir/xray/proxyip.csv`）保持同一相对位置，两端可互换。
  Future<File> _proxyIpFile() async {
    final dir = await Paths.xray();
    return File('${dir.path}/proxyip.csv');
  }

  /// proxyip 使用状态文件的路径（对应原版 `proxyip-state.json`）。
  Future<File> _proxyIpStateFile() async {
    final dir = await Paths.xray();
    return File('${dir.path}/proxyip-state.json');
  }

  /// 每个 proxyip 的成功/失败统计 + 上次成功的那个。
  ///
  /// 只用于排序（哪条先试），不做排行榜 UI。
  ProxyIpState proxyIpState = const ProxyIpState();

  /// 按「失败少 → 最近成功 → 上次成功的优先」排好序的 proxyip 列表。
  List<ProxyIp> get orderedProxyPool => orderProxyIps(proxyPool, proxyIpState);

  /// 记一次 proxyip 的使用结果并落盘。
  ///
  /// [item] 为 null 表示这次没用 proxyip（链接原样），不记账。
  Future<void> recordProxyResult(ProxyIp? item, bool ok) async {
    if (item == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    proxyIpState = ok
        ? proxyIpState.recordSuccess(item.key, nowMs: now)
        : proxyIpState.recordFailure(item.key, nowMs: now);
    notifyListeners();
    try {
      final file = await _proxyIpStateFile();
      await file.writeAsString(proxyIpState.encode(), flush: true);
    } catch (e) {
      pushLog('保存 proxyip 状态失败：$e');
    }
  }

  /// 启动时载入 proxyip.csv。
  ///
  /// **只在用户还没在设置里手输过时载入**：设置里的列表是显式编辑的，
  /// 被文件悄悄覆盖会让人以为「我改的怎么没了」。
  Future<void> _loadProxyIps() async {
    try {
      // 使用状态独立于列表：它决定「哪条先试」，没有列表也不影响
      final stateFile = await _proxyIpStateFile();
      if (await stateFile.exists()) {
        proxyIpState = ProxyIpState.decode(await stateFile.readAsString());
      }
      if (settings.proxyIps.isNotEmpty) return;
      final file = await _proxyIpFile();
      if (!await file.exists()) return;
      final parsed = parseProxyIpCsv(await file.readAsString());
      if (parsed.isEmpty) return;
      settings.proxyIps = parsed.map((item) => item.key).toList();
      notifyListeners();
      pushLog('已从 proxyip.csv 载入 ${parsed.length} 条');
    } catch (e) {
      pushLog('读取 proxyip.csv 失败：$e');
    }
  }

  /// 导入 proxyip 文本（4 列 CSV 或每行 `ip:port`）。返回导入条数。
  ///
  /// 解析规则见 `lib/data/proxy_ip_csv.dart`：坏行跳过、按 `ip:port` 去重。
  Future<int> importProxyIps(String text) async {
    final parsed = parseProxyIpCsv(text);
    if (parsed.isEmpty) {
      throw Exception(
        '没有解析出任何 proxyip（支持 CSV 的「IP,Port,...」或每行一个 ip:port）',
      );
    }
    final file = await _proxyIpFile();
    await file.writeAsString(toProxyIpCsv(parsed), flush: true);
    settings.proxyIps = parsed.map((item) => item.key).toList();
    await saveSettings();
    pushLog('已导入 ${parsed.length} 条 proxyip');
    return parsed.length;
  }

  /// 清空 proxyip：删文件 + 清内存 + 落设置（对应原版 `ProxyIpRepository.clear()`）。
  Future<void> clearProxyIps() async {
    try {
      final file = await _proxyIpFile();
      if (await file.exists()) await file.delete();
    } catch (e) {
      pushLog('删除 proxyip.csv 失败：$e');
    }
    settings.proxyIps = const [];
    await saveSettings();
    pushLog('已清空 proxyip 列表');
  }

  /// 预释放二进制，避免第一次测试时卡几秒。
  Future<void> _warmBinaries() async {
    try {
      await Bins.path('pipeline');
      binStatus = '引擎就绪';
    } catch (e) {
      binStatus = '引擎异常：$e';
    }
    notifyListeners();
  }

  Future<void> saveSettings() async {
    await settings.save();
    // 保存后立刻换端点：下一轮测速就该用新地址，不必等重启。
    _applyLinkTestUrls();
    notifyListeners();
  }

  /// 直接在内存里改过 [settings] 之后，通知 UI 重绘。
  ///
  /// 为什么需要它：设置页保存失败时要把乐观写入**回滚**（内存与磁盘保持一致），
  /// 回滚本身不落盘、也没有 `notifyListeners` 的时机；少了这一次通知，摘要行
  /// 会继续显示「已经存上」的新值，用户就被骗了。只通知、不写盘、不换端点
  /// —— 它不能替代 [saveSettings]。
  void notifySettingsChanged() => notifyListeners();

  /// 把设置里的「延迟/速度测试地址」灌进测速 runner。
  ///
  /// 两个地址是**两条口径**（延迟 = 小端点、速度 = 大文件），必须分开灌；
  /// 合成一个字段就是「延迟读数和 v2rayN 不可比」的老 bug。
  void _applyLinkTestUrls() {
    linkTestRunner.configureUrls(
      speedUrl: settings.speedUrl,
      latencyUrl: settings.latencyUrl,
    );
  }

  void pushLog(String line) {
    logs.add(line);
    if (logs.length > 2000) {
      logs.removeRange(0, logs.length - 2000);
    }
    notifyListeners();
  }

  void clearLogs() {
    logs.clear();
    notifyListeners();
  }

  Vless? get primaryLine {
    for (final link in settings.vlessLinks) {
      final v = Vless.tryParse(link);
      if (v != null) return v;
    }
    return null;
  }

  List<ProxyIp> get proxyPool => parseProxyCsv(settings.proxyIps.join('\n'));

  /// 用指定 proxyip 启动一条临时代理（null = 链接原样，不换回源 path）。
  ///
  /// 供抓取 / 推送 GitHub 短时调用；与已删除的「线路页手动启停」不同，
  /// 这个入口是工作流程内部使用的，调用方负责在用完后 [stopProxyLine]。
  Future<void> startProxyLine(ProxyIp? proxy) async {
    final v = primaryLine;
    if (v == null) throw Exception('先在「线路与代理」填一条 vless 链接');
    await xray.start(v, proxy: proxy);
    notifyListeners();
  }

  Future<void> stopProxyLine() async {
    await xray.stop();
    notifyListeners();
  }

  /// 本地测试。返回是否成功。
  ///
  /// [mode] 为 `latency`（只延迟）/ `speed`（只速度）/ `both`（延迟+速度），
  /// 由 [Pipeline.run] 映射到对应的 Go flag。
  Future<bool> runLocal({required String mode, required String input}) async {
    if (running) throw Exception('上一次测试还在进行');
    if (input.trim().isEmpty) throw Exception('先选择记录或导入抓取结果');

    final modeLabel = switch (mode) {
      'latency' => '延迟测试',
      'speed' => '速度测试',
      _ => '延迟 + 速度',
    };

    running = true;
    lastError = null;
    rows = const [];
    clearLogs();
    progressCur = 0;
    progressTotal = 0;
    progressStage = '准备中（$modeLabel）';
    pushLog('▶ 本地测试：$modeLabel');
    notifyListeners();

    try {
      final token = PipelineCancelToken();
      _runToken = token;
      final out = await Pipeline.run(
        mode: mode,
        input: input,
        settings: settings,
        onLine: pushLog,
        token: token,
        onProgress: (cur, total, stage) {
          progressCur = cur;
          progressTotal = total;
          progressStage = stage;
          notifyListeners();
        },
      );
      rows = out.rows;
      lastRunDir = out.dir;
      return true;
    } catch (e) {
      lastError = e.toString();
      pushLog('✗ $e');
      return false;
    } finally {
      _runToken = null;
      running = false;
      notifyListeners();
    }
  }

  Future<void> cancel() async {
    // 三阶段取消：必须走 Process 句柄 kill。旧实现按进程名匹配去杀，
    // 匹配不到真实可执行文件（nativeLibraryDir/libpipeline.so），
    // 是彻底的空操作 —— 用户以为取消了，进程还在跑（取消链路三段）。
    final token = _runToken;
    if (token == null) {
      pushLog('没有正在运行的三阶段测试');
      return;
    }
    pushLog('正在取消…');
    await token.cancel();
    pushLog('已取消');
  }

  /// 跑一次链路测速。返回是否成功（失败原因在 [linkTestError]）。
  ///
  /// 与三阶段本地测试互斥：两者都会重压 CPU/网络，同时跑测出来的数没意义。
  Future<bool> runLinkTest(
    List<String> links, {
    LinkTestMode mode = LinkTestMode.auto,
  }) async {
    // 防重入必须在**任何状态改写之前**：否则第二次调用会先把 linkResults 清空
    // （抹掉第一轮进度），再被 runner 抛「上一次测速还在进行」，最后 finally 把
    // linkTestRunning 置 false —— 第一轮还在跑，UI 却以为没在跑。
    // 判据用 runner 自己的运行态（唯一真相），不看 linkTestRunning 这个副本。
    //
    // `cancelled` 要一起看：取消是异步收尾的（关 HttpClient / 停进程），
    // 收尾期间 runner.running 仍为 true。若这里照旧拒绝，用户「取消 → 立刻开始」
    // 就会看到「测速进行中，请先停止测速」——runner 那边其实能等上一轮收尾，
    // 两层判据必须一致，否则永远开不出第二轮。
    if (linkTestRunner.running && !linkTestRunner.cancelled) {
      linkTestError = '测速进行中，请先停止测速';
      notifyListeners();
      return false;
    }
    if (running) {
      linkTestError = '三阶段测试进行中，请先等待完成';
      notifyListeners();
      return false;
    }
    // 轮次令牌：这一轮从此刻起独占 linkResults / linkStage / linkTestRunning。
    //
    // 为什么必须有：取消后立刻再开一轮时，**上一轮** `await runner.run(...)` 的
    // 续体会比新一轮启动更晚恢复执行（runner 侧新一轮的续体先跑，它会把
    // `_cancelled` 重置为 false）。上一轮照着旧结果写副本状态，就会把
    // 「第二轮正在跑」踩成「完成 + 第一轮的已取消结果」，`finally` 还会把
    // `linkTestRunning` 拉成 false。runner 内部的 `_epoch` 管不到 AppState
    // 这份副本，只能在这里自己判。
    final token = ++_linkRunToken;
    linkTestRunning = true;
    linkTestError = null;
    linkResults = const [];
    linkStage = '准备中';
    notifyListeners();

    try {
      final run = await linkTestRunner.run(
        links,
        mode: mode,
        onProgress: (results, stage) {
          if (!_isCurrentLinkRun(token)) return; // 陈旧轮次不许再刷 UI
          linkResults = results;
          linkStage = stage;
          notifyListeners();
        },
      );
      // 陈旧轮次到这里说明已被新一轮接管：**一个字段都不许再碰**，
      // 也不返回 false —— 那会让 UI 弹出属于新一轮的 linkTestError。
      if (!_isCurrentLinkRun(token)) return true;
      linkResults = run.results;
      linkStage = linkTestRunner.cancelled ? '已取消' : '完成';
      // 有失败就把 Xray 侧的最后几行原始输出带进日志：
      // 链路失败时 Dart 只能看到「TLS 握手失败 / 连接被重置」，
      // 真正原因（比如 splithttp: bad status code 403）只在 Xray stderr 里。
      final failed = run.results.where((r) => r.error != null).length;
      if (failed > 0) {
        final tail = xray.lastOutput
            .where((l) => l.trim().isNotEmpty)
            .toList(growable: false);
        final from = tail.length > 8 ? tail.length - 8 : 0;
        if (tail.isNotEmpty) pushLog('— Xray 输出（最后 ${tail.length - from} 行）—');
        for (var i = from; i < tail.length; i++) {
          pushLog('  ${tail[i]}');
        }
      }
      // K4：只提示、不自动恢复代理（R12 = A：代理是否恢复由用户下一次显式动作决定）
      if (linkTestRunner.stoppedUserProxy) {
        _proxyStopNotice = kProxyStoppedByTestMessage;
        pushLog(kProxyStoppedByTestMessage);
      }
      return true;
    } on LinkTestException catch (e) {
      if (!_isCurrentLinkRun(token)) return true;
      linkTestError = e.message;
      pushLog('✗ ${e.message}');
      return false;
    } on Object catch (e) {
      if (!_isCurrentLinkRun(token)) return true;
      linkTestError = e.toString();
      pushLog('✗ $e');
      return false;
    } finally {
      // 只有**当前**轮次才有资格把「没在跑」写回去；否则会把正在跑的新一轮
      // 标成空闲，UI 立刻放出「开始测试」按钮，用户点下去又是一次冲突。
      if (_isCurrentLinkRun(token)) {
        linkTestRunning = false;
        notifyListeners();
      }
    }
  }

  /// 这一轮是否仍然「当前」（没被后续 runLinkTest 抢走）。
  ///
  /// 与 runner 内部的 `_epoch` 是同一套思路：跨层共享状态时，谁最后启动谁说了算，
  /// 先启动者的迟到回调一律作废。
  bool _isCurrentLinkRun(int token) => token == _linkRunToken;

  /// 取消测速：置位 → 关在途客户端 → 杀批量进程（三段由 runner 内部完成）。
  Future<void> cancelLinkTest() async {
    // 取令牌要**在 await 之前**：`runner.cancel()` 是异步收尾（关 HttpClient、
    // 停批量进程），这段时间用户完全可能已经点「开始」开出新一轮。若这里
    // 无条件写 `linkStage`，就会把新轮的「准备中/延迟探测」改回「已取消」，
    // 用户看到「已取消」但其实在测。这个错误下一帧会被 onProgress 自愈，
    // 所以不算致命，但既然 runLinkTest 已有令牌，这里没理由不跟着判。
    final token = _linkRunToken;
    final wasRunning = linkTestRunner.running;
    await linkTestRunner.cancel();
    // 已被新一轮接管 → 一个字段都别碰。
    if (!_isCurrentLinkRun(token)) return;
    // 什么都没在跑时 runner.cancel() 直接 return：此时不该凭空显示「已取消」。
    if (!wasRunning) return;
    linkStage = '已取消';
    notifyListeners();
  }

  List<(String, String)> get usableTargets {
    final out = <(String, String)>[];
    for (final r in rows) {
      if ((r['Reason'] ?? '').isNotEmpty) continue;
      final ip = r['IP'] ?? '';
      final port = r['Port'] ?? '';
      if (ip.isEmpty || port.isEmpty) continue;
      out.add((ip, port));
    }
    return out;
  }

  int get usableCount => usableTargets.length;

  double get fastestSpeed {
    var best = 0.0;
    for (final r in rows) {
      if ((r['Reason'] ?? '').isNotEmpty) continue;
      final v = double.tryParse(r['Speed (MiB/s)'] ?? '') ?? 0;
      if (v > best) best = v;
    }
    return best;
  }

  int get averageLatency {
    final lats = rows
        .where((r) => (r['Reason'] ?? '').isEmpty)
        .map((r) => int.tryParse(r['Latency (ms)'] ?? '') ?? 0)
        .where((v) => v > 0)
        .toList();
    if (lats.isEmpty) return 0;
    return lats.reduce((a, b) => a + b) ~/ lats.length;
  }

  Future<void> loadRun(String id) async {
    final loaded = await Pipeline.readRunResult(id);
    if (loaded.isEmpty) throw Exception('该记录没有结果');
    rows = loaded;
    notifyListeners();
  }

  Future<void> saveArchive(String body) async {
    try {
      await History.saveArchive(body);
    } catch (_) {
      // 存档失败不影响主流程
    }
  }
}
