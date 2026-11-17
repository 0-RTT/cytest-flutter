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
  static const maxLatency = 200;
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
  String httpProxy;
  String fetchProxy;
  List<String> vlessLinks;
  List<String> proxyIps;
  String githubToken;
  String githubRepo;
  String githubPath;
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
    this.httpProxy = '',
    this.fetchProxy = '',
    this.vlessLinks = const [],
    this.proxyIps = const [],
    this.githubToken = '',
    this.githubRepo = '',
    this.githubPath = '',
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

  AppSettings copyWith({
    String? githubToken,
    String? githubRepo,
    String? githubPath,
    String? remoteHost,
    int? remotePort,
    String? remoteUser,
    String? remotePassword,
    String? remoteKeyPath,
  }) =>
      AppSettings(
        speedUrl: speedUrl,
        fingerprint: fingerprint,
        sha1Concurrency: sha1Concurrency,
        latencyConcurrency: latencyConcurrency,
        speedConcurrency: speedConcurrency,
        dialTimeout: dialTimeout,
        downloadTimeout: downloadTimeout,
        maxLatency: maxLatency,
        httpProxy: httpProxy,
        fetchProxy: fetchProxy,
        vlessLinks: vlessLinks,
        proxyIps: proxyIps,
        githubToken: githubToken ?? this.githubToken,
        githubRepo: githubRepo ?? this.githubRepo,
        githubPath: githubPath ?? this.githubPath,
        remoteHost: remoteHost ?? this.remoteHost,
        remotePort: remotePort ?? this.remotePort,
        remoteUser: remoteUser ?? this.remoteUser,
        remotePassword: remotePassword ?? this.remotePassword,
        remoteKeyPath: remoteKeyPath ?? this.remoteKeyPath,
      );

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        speedUrl: json['speedUrl'] as String? ?? Defaults.speedUrl,
        fingerprint: json['fingerprint'] as String? ?? Defaults.fingerprint,
        sha1Concurrency: json['sha1Concurrency'] as int? ?? Defaults.sha1Concurrency,
        latencyConcurrency:
            json['latencyConcurrency'] as int? ?? Defaults.latencyConcurrency,
        speedConcurrency:
            json['speedConcurrency'] as int? ?? Defaults.speedConcurrency,
        dialTimeout: json['dialTimeout'] as int? ?? Defaults.dialTimeout,
        downloadTimeout:
            json['downloadTimeout'] as int? ?? Defaults.downloadTimeout,
        maxLatency: json['maxLatency'] as int? ?? Defaults.maxLatency,
        httpProxy: json['httpProxy'] as String? ?? '',
        fetchProxy: json['fetchProxy'] as String? ?? '',
        vlessLinks: (json['vlessLinks'] as List?)?.cast<String>() ?? const [],
        proxyIps: (json['proxyIps'] as List?)?.cast<String>() ?? const [],
        githubToken: json['githubToken'] as String? ?? '',
        githubRepo: json['githubRepo'] as String? ?? '',
        githubPath: json['githubPath'] as String? ?? '',
        remoteHost: json['remoteHost'] as String? ?? '',
        remotePort: json['remotePort'] as int? ?? 22,
        remoteUser: json['remoteUser'] as String? ?? 'root',
        remotePassword: json['remotePassword'] as String? ?? '',
        remoteKeyPath: json['remoteKeyPath'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'speedUrl': speedUrl,
        'fingerprint': fingerprint,
        'sha1Concurrency': sha1Concurrency,
        'latencyConcurrency': latencyConcurrency,
        'speedConcurrency': speedConcurrency,
        'dialTimeout': dialTimeout,
        'downloadTimeout': downloadTimeout,
        'maxLatency': maxLatency,
        'httpProxy': httpProxy,
        'fetchProxy': fetchProxy,
        'vlessLinks': vlessLinks,
        'proxyIps': proxyIps,
        'githubToken': githubToken,
        'githubRepo': githubRepo,
        'githubPath': githubPath,
        'remoteHost': remoteHost,
        'remotePort': remotePort,
        'remoteUser': remoteUser,
        'remotePassword': remotePassword,
        'remoteKeyPath': remoteKeyPath,
      };
}
