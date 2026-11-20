import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 默认参数，与 Android 端 Defaults.kt / 桌面端 main.go 保持一致。
class Defaults {
  static const fingerprint = '108b6115dc6ebfde76aef4336126f605252d957f';
  static const speedUrl = 'https://е.eu.org/300.zip';

  /// 延迟阶段的目标地址（204 小端点，无 body、无跳转）。
  ///
  /// 与 [kDefaultLatencyUrl]（`lib/data/link_probe.dart`）必须**逐字一致**：
  /// 这里不能 import 那份常量（core 层不依赖 data 层），所以靠单测
  /// `test/link_probe_test.dart` 的「默认值三条必须对齐」钉住，改一处漏一处会红。
  ///
  /// 为什么默认值要和 [speedUrl] 分开：大文件端点的首字节会被服务端/链路缓冲
  /// 推迟，且常带跨主机 302，跟着跳转还会把第二套 CONNECT/TLS 算进 TTFB ——
  /// 三条叠加就是「延迟读数远大于 v2rayN」的根因。
  static const latencyUrl = 'https://cp.cloudflare.com/generate_204';

  static const sha1Concurrency = 30;
  static const latencyConcurrency = 100;
  static const speedConcurrency = 3;
  static const dialTimeout = 5;
  static const downloadTimeout = 10;

  /// 一键测试的延迟筛选阈值，**0 = 不限**。
  ///
  /// 语义澄清：这个值只用来「跳过太慢的候选、省测速时间」，**不承担
  /// 判定节点可用的职责**。能用的候选在延迟阶段已经用统一口径
  /// （纯 TCP 握手，与原版 `measureTCPLatency` 一致）筛过一遍了。
  ///
  /// v1.0.19 之前这里是 200ms。延迟口径曾经被改成「HTTP 响应头到达」，
  /// 跨境候选普遍 300~1500ms，200ms 会把大量本来能用的节点整批标成
  /// 「超过阈值」，用户看到的就是「一键测试全部失败」。所以默认改为 0。
  static const maxLatency = 0;

  /// 推送到 GitHub 的**订阅文件名**（base64 文本）。
  ///
  /// 放在设置里而不是推送页：一次配好长期复用，避免每次都手填（推送页
  /// 那个输入框已按需求移除）。
  static const subPath = 'cytest-sub.txt';

  /// 推送到 GitHub 的 **mihomo YAML 文件名**。
  static const yamlPath = 'config.yaml';

  /// v1.0.19 及更早版本的默认值，仅用于一次性迁移识别（见 AppSettings.fromJson）。
  static const legacyMaxLatency = 200;

  /// v1.0.24 及更早版本的测速并发默认值，同样只用于一次性迁移识别。
  static const legacySpeedConcurrency = 2;

  static const asn = 45090;

  /// CQL 查询模板，与 Android 端 buildQuery 一致。
  static String buildQuery(String fingerprint) =>
      'host.autonomous_system.asn:$asn'
      ' and host.services.endpoints.http.body_hash_sha1="$fingerprint"'
      ' and not host.labels.value:IPV6';
}

class AppSettings {
  /// 速度阶段地址（大文件端点；3s / 64MiB 吞吐窗口靠它）。
  String speedUrl;

  /// 延迟阶段地址（小端点，默认 [Defaults.latencyUrl]）。
  ///
  /// 老版本的 JSON 里没有这个键，[fromJson] 会回落到 [Defaults.latencyUrl]
  /// —— 绝不能因为「没这个键」就留空串，那会让每条线路都报「地址非法」。
  String latencyUrl;

  String fingerprint;
  int sha1Concurrency;
  int latencyConcurrency;
  int speedConcurrency;
  int dialTimeout;
  int downloadTimeout;
  int maxLatency;

  /// 「默认延迟阈值已改 0」这次迁移是否已经落到这份设置里。
  ///
  /// 只做一次的原因：迁移靠「值恰好等于旧默认 200 且没有标记」来识别老数据。
  /// 打完标记之后，用户再手填 200 就是他自己的选择，不能再被下次启动改掉。
  bool latencyThresholdMigrated;

  /// 「测速并发默认值 2 → 3」这次迁移是否已经落到这份设置里。
  ///
  /// 与 [latencyThresholdMigrated] 同一套做法：只认「恰好等于旧默认 2」且没有标记的
  /// 老数据，迁到 3 之后打标记；用户此后手填 2 就是他自己的选择，不再被覆盖。
  bool speedConcurrencyMigrated;

  /// 已停用：原版 Kotlin 没有「测速代理」这个概念，优选 IP 测速始终直连
  /// （`LocalSpeedProtocol.configJson` 不含 httpProxy，`LocalSpeedRunner` 也不传 `-proxy`）。
  ///
  /// 字段保留只为兼容旧 `settings.json` / 备份文件的读写，**任何代码都不该再读它**；
  /// `Pipeline._configJson` 已不再写入，UI 入口也已移除。
  /// 历史事故：填一个非 HTTP 代理的地址（节点端口 / CDN 入口）会让全部候选报
  /// 「代理隧道失败」，看起来像「所有节点都挂了」。
  String httpProxy;

  String fetchProxy;
  List<String> vlessLinks;
  List<String> proxyIps;
  String githubToken;

  /// 已规范化的 `owner/repo`（设置页保存时用 parseRepoSlug 转过）。
  String githubRepo;

  /// GitHub 推送的两个文件名（见 [Defaults.subPath] / [Defaults.yamlPath]）。
  String subPath;
  String yamlPath;
  String remoteHost;
  int remotePort;
  String remoteUser;
  String remotePassword;
  String remoteKeyPath;

  AppSettings({
    this.speedUrl = Defaults.speedUrl,
    this.latencyUrl = Defaults.latencyUrl,
    this.fingerprint = Defaults.fingerprint,
    this.sha1Concurrency = Defaults.sha1Concurrency,
    this.latencyConcurrency = Defaults.latencyConcurrency,
    this.speedConcurrency = Defaults.speedConcurrency,
    this.dialTimeout = Defaults.dialTimeout,
    this.downloadTimeout = Defaults.downloadTimeout,
    this.maxLatency = Defaults.maxLatency,
    this.latencyThresholdMigrated = true,
    this.speedConcurrencyMigrated = true,
    this.httpProxy = '',
    this.fetchProxy = '',
    this.vlessLinks = const [],
    this.proxyIps = const [],
    this.githubToken = '',
    this.githubRepo = '',
    this.subPath = Defaults.subPath,
    this.yamlPath = Defaults.yamlPath,
    this.remoteHost = '',
    this.remotePort = 22,
    this.remoteUser = 'root',
    this.remotePassword = '',
    this.remoteKeyPath = '',
  });

  static const _key = 'cytest.settings.v1';

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return AppSettings();
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(toJson()));
  }

  /// 读盘。这里藏了一次**一次性迁移**，见 [_migrateMaxLatency]。
  ///
  /// 数值字段一律用 `(json[x] as num?)?.toInt()` 而不是 `as int?`：
  /// 若存量 json 里出现 `200.0`（double），`as int?` 会抛 TypeError，
  /// 被 [load] 的 catch 吞掉后**整份设置静默重置成默认值** ——
  /// 用户丢的是全部配置，而不只是一个字段。
  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        // 与 latencyUrl 同一条归一化：`??` 挡不住空串，而空串一路传到
        // pipeline 的 speedTestURL 会让三阶段下载直接报错。
        speedUrl: _readUrl(json['speedUrl'], Defaults.speedUrl),
        // 老 JSON 没有 latencyUrl：回落默认小端点。空串也按「没配」处理——
        // 空地址会让 latency() 抛「地址非法」，而用户并没有表达「关闭延迟」。
        latencyUrl: _readUrl(json['latencyUrl'], Defaults.latencyUrl),
        fingerprint: json['fingerprint'] as String? ?? Defaults.fingerprint,
        sha1Concurrency: (json['sha1Concurrency'] as num?)?.toInt() ??
            Defaults.sha1Concurrency,
        latencyConcurrency: (json['latencyConcurrency'] as num?)?.toInt() ??
            Defaults.latencyConcurrency,
        speedConcurrency: _migrateSpeedConcurrency(json),
        dialTimeout:
            (json['dialTimeout'] as num?)?.toInt() ?? Defaults.dialTimeout,
        downloadTimeout: (json['downloadTimeout'] as num?)?.toInt() ??
            Defaults.downloadTimeout,
        maxLatency: _migrateMaxLatency(json),
        // 读进来的这份设置今后都算「已迁移」：toJson 会把这个标记写回去，
        // 下次启动就不会再触发迁移。
        latencyThresholdMigrated: true,
        speedConcurrencyMigrated: true,
        httpProxy: json['httpProxy'] as String? ?? '',
        fetchProxy: json['fetchProxy'] as String? ?? '',
        vlessLinks: (json['vlessLinks'] as List?)?.cast<String>() ?? const [],
        proxyIps: (json['proxyIps'] as List?)?.cast<String>() ?? const [],
        githubToken: json['githubToken'] as String? ?? '',
        githubRepo: json['githubRepo'] as String? ?? '',
        // 老 JSON 没有这两个键 → 回落默认；空串同样回落（清空文件名会让
        // 推送写到仓库根目录，等于把文件铺在根上，绝大多数人都不是这个意思）。
        subPath: _readUrl(json['subPath'], Defaults.subPath),
        yamlPath: _readUrl(json['yamlPath'], Defaults.yamlPath),
        remoteHost: json['remoteHost'] as String? ?? '',
        remotePort: (json['remotePort'] as num?)?.toInt() ?? 22,
        remoteUser: json['remoteUser'] as String? ?? 'root',
        remotePassword: json['remotePassword'] as String? ?? '',
        remoteKeyPath: json['remoteKeyPath'] as String? ?? '',
      );

  /// 读一个「地址」型字段：缺键 / 非字符串 / 空白都回落 [fallback]。
  ///
  /// 与 `speedUrl` 的 `?? Defaults.speedUrl` 同一套写法，只是多挡一层空白串：
  /// 空白地址会让探测直接报「地址非法」，用户在设置页删空输入框时不该
  /// 得到「所有线路失败」这种后果。
  static String _readUrl(Object? value, String fallback) {
    if (value is! String) return fallback;
    final trimmed = value.trim();
    return trimmed.isEmpty ? fallback : trimmed;
  }

  /// 把老用户存下来的 `maxLatency: 200` 迁到新默认 `0`（不限）。
  ///
  /// 为什么要迁：200ms 是「延迟 = TCP 握手」时代的默认值。口径改成
  /// 「HTTP 响应头到达」后，200ms 会把大量跨境但完全能用的候选筛掉，
  /// 一键测试看起来像「全部失败」。只改 `Defaults` 不够 —— 老用户的
  /// `200` 早就落盘了，会继续生效。
  ///
  /// 为什么只做一次、且只认「恰好等于 200」：
  /// - 打到 200 的老数据无法区分「从没改过（默认）」和「特意设成 200」，
  ///   这里选择按「从没改过」处理 —— 这正是本次要修的默认值问题；
  /// - 其它数值（150 / 300 / 1500）都是用户明确设过的，一律不动；
  /// - 迁移后 `toJson` 会写 `latencyThresholdMigrated: true`，此后
  ///   用户再手填 200 也不会被覆盖。
  static int _migrateMaxLatency(Map<String, dynamic> json) {
    final stored = (json['maxLatency'] as num?)?.toInt() ?? Defaults.maxLatency;
    final migrated = json['latencyThresholdMigrated'] as bool? ?? false;
    if (!migrated && stored == Defaults.legacyMaxLatency) {
      return Defaults.maxLatency;
    }
    return stored;
  }

  /// 把老用户存下来的 `speedConcurrency: 2` 迁到新默认 `3`。
  ///
  /// 为什么迁：2 是「本地带宽有限、并发少单条更准」时代的默认值；实测 3 并发
  /// 在移动网络下既不会互相抢带宽，又能把整轮耗时压下来约三分之一。
  /// 只改 `Defaults` 不够 —— 老用户的 2 早已落盘。
  static int _migrateSpeedConcurrency(Map<String, dynamic> json) {
    final stored = (json['speedConcurrency'] as num?)?.toInt() ??
        Defaults.speedConcurrency;
    final migrated = json['speedConcurrencyMigrated'] as bool? ?? false;
    if (!migrated && stored == Defaults.legacySpeedConcurrency) {
      return Defaults.speedConcurrency;
    }
    return stored;
  }

  Map<String, dynamic> toJson() => {
        'speedUrl': speedUrl,
        // 必须写回：漏写这一行，用户点一次保存就会把延迟地址「删掉」，
        // 下次启动回落默认值——看起来像「设置没生效」。
        'latencyUrl': latencyUrl,
        'fingerprint': fingerprint,
        'sha1Concurrency': sha1Concurrency,
        'latencyConcurrency': latencyConcurrency,
        'speedConcurrency': speedConcurrency,
        'dialTimeout': dialTimeout,
        'downloadTimeout': downloadTimeout,
        'maxLatency': maxLatency,
        // 迁移标记：写下之后，「200 就是用户自己选的」不会再被改成 0。
        'latencyThresholdMigrated': true,
        'speedConcurrencyMigrated': true,
        'httpProxy': httpProxy,
        'fetchProxy': fetchProxy,
        'vlessLinks': vlessLinks,
        'proxyIps': proxyIps,
        'githubToken': githubToken,
        'githubRepo': githubRepo,
        // 必须写回：漏写会在下次启动把用户设的文件名回落到默认值。
        'subPath': subPath,
        'yamlPath': yamlPath,
        'remoteHost': remoteHost,
        'remotePort': remotePort,
        'remoteUser': remoteUser,
        'remotePassword': remotePassword,
        'remoteKeyPath': remoteKeyPath,
      };
}
