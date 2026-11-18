import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 默认参数，与 Android 端 Defaults.kt / 桌面端 main.go 保持一致。
class Defaults {
  static const fingerprint = '108b6115dc6ebfde76aef4336126f605252d957f';
  static const speedUrl = 'https://е.eu.org/300.zip';
  static const sha1Concurrency = 30;
  static const latencyConcurrency = 100;
  static const speedConcurrency = 2;
  static const dialTimeout = 5;
  static const downloadTimeout = 10;

  /// 一键测试的延迟筛选阈值，**0 = 不限**。
  ///
  /// 语义澄清：这个值只用来「跳过太慢的候选、省测速时间」，**不承担
  /// 判定节点可用的职责**。能用的候选在延迟阶段已经用统一口径
  /// （TCP + TLS/SNI + HTTP 响应头）筛过一遍了。
  ///
  /// v1.0.19 之前这里是 200ms。延迟口径从「TCP 握手」改成「HTTP 响应头到达」
  /// 之后，跨境候选普遍 300~1500ms，200ms 会把大量本来能用的节点整批标成
  /// 「超过阈值」，用户看到的就是「一键测试全部失败」。所以默认改为 0。
  static const maxLatency = 0;

  /// v1.0.19 及更早版本的默认值，仅用于一次性迁移识别（见 AppSettings.fromJson）。
  static const legacyMaxLatency = 200;

  static const asn = 45090;

  /// CQL 查询模板，与 Android 端 buildQuery 一致。
  static String buildQuery(String fingerprint) =>
      'host.autonomous_system.asn:$asn'
      ' and host.services.endpoints.http.body_hash_sha1="$fingerprint"'
      ' and not host.labels.value:IPV6';
}

class AppSettings {
  String speedUrl;
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

  String httpProxy;
  String fetchProxy;
  List<String> vlessLinks;
  List<String> proxyIps;
  String githubToken;

  /// 已规范化的 `owner/repo`（设置页保存时用 parseRepoSlug 转过）。
  String githubRepo;
  String remoteHost;
  int remotePort;
  String remoteUser;
  String remotePassword;
  String remoteKeyPath;

  AppSettings({
    this.speedUrl = Defaults.speedUrl,
    this.fingerprint = Defaults.fingerprint,
    this.sha1Concurrency = Defaults.sha1Concurrency,
    this.latencyConcurrency = Defaults.latencyConcurrency,
    this.speedConcurrency = Defaults.speedConcurrency,
    this.dialTimeout = Defaults.dialTimeout,
    this.downloadTimeout = Defaults.downloadTimeout,
    this.maxLatency = Defaults.maxLatency,
    this.latencyThresholdMigrated = true,
    this.httpProxy = '',
    this.fetchProxy = '',
    this.vlessLinks = const [],
    this.proxyIps = const [],
    this.githubToken = '',
    this.githubRepo = '',
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
        speedUrl: json['speedUrl'] as String? ?? Defaults.speedUrl,
        fingerprint: json['fingerprint'] as String? ?? Defaults.fingerprint,
        sha1Concurrency:
            (json['sha1Concurrency'] as num?)?.toInt() ?? Defaults.sha1Concurrency,
        latencyConcurrency:
            (json['latencyConcurrency'] as num?)?.toInt() ?? Defaults.latencyConcurrency,
        speedConcurrency:
            (json['speedConcurrency'] as num?)?.toInt() ?? Defaults.speedConcurrency,
        dialTimeout: (json['dialTimeout'] as num?)?.toInt() ?? Defaults.dialTimeout,
        downloadTimeout:
            (json['downloadTimeout'] as num?)?.toInt() ?? Defaults.downloadTimeout,
        maxLatency: _migrateMaxLatency(json),
        // 读进来的这份设置今后都算「已迁移」：toJson 会把这个标记写回去，
        // 下次启动就不会再触发迁移。
        latencyThresholdMigrated: true,
        httpProxy: json['httpProxy'] as String? ?? '',
        fetchProxy: json['fetchProxy'] as String? ?? '',
        vlessLinks: (json['vlessLinks'] as List?)?.cast<String>() ?? const [],
        proxyIps: (json['proxyIps'] as List?)?.cast<String>() ?? const [],
        githubToken: json['githubToken'] as String? ?? '',
        githubRepo: json['githubRepo'] as String? ?? '',
        remoteHost: json['remoteHost'] as String? ?? '',
        remotePort: (json['remotePort'] as num?)?.toInt() ?? 22,
        remoteUser: json['remoteUser'] as String? ?? 'root',
        remotePassword: json['remotePassword'] as String? ?? '',
        remoteKeyPath: json['remoteKeyPath'] as String? ?? '',
      );

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

  Map<String, dynamic> toJson() => {
        'speedUrl': speedUrl,
        'fingerprint': fingerprint,
        'sha1Concurrency': sha1Concurrency,
        'latencyConcurrency': latencyConcurrency,
        'speedConcurrency': speedConcurrency,
        'dialTimeout': dialTimeout,
        'downloadTimeout': downloadTimeout,
        'maxLatency': maxLatency,
        // 迁移标记：写下之后，「200 就是用户自己选的」不会再被改成 0。
        'latencyThresholdMigrated': true,
        'httpProxy': httpProxy,
        'fetchProxy': fetchProxy,
        'vlessLinks': vlessLinks,
        'proxyIps': proxyIps,
        'githubToken': githubToken,
        'githubRepo': githubRepo,
        'remoteHost': remoteHost,
        'remotePort': remotePort,
        'remoteUser': remoteUser,
        'remotePassword': remotePassword,
        'remoteKeyPath': remoteKeyPath,
      };
}
