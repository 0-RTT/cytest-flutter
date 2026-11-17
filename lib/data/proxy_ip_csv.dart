/// proxyip 列表的读写与「哪条先用」的排序。
///
/// **关键事实：proxyip 文件就是测速结果 CSV**。原版
/// `ProxyIpRepository.parseCsv` 直接委托给 `SpeedResultCsv.parse(text)`，
/// 所以用户可以把测速跑出来的 `result.csv` 直接当 proxyip 文件导入：
/// ```
/// IP,Port,Latency (ms),Speed (MiB/s)[,Reason]
/// 104.16.0.1,443,120,8.50
/// ```
/// 因此这里**不自己写一套 CSV 规则**，而是复用 `pipeline.dart` 的
/// `parseSpeedCsvRows` / `toSpeedCsvText`（那边已覆盖引号、BOM、CRLF、表头、
/// 注释行、非法行跳过）。两套规则以后必然分叉，这是刻意避免的。
library;

import 'dart:convert';

import 'pipeline.dart';
import 'vless.dart';

/// 解析 proxyip 文件（测速结果 CSV 格式），按 `ip:port` 去重并保留首次出现顺序。
List<ProxyIp> parseProxyIpCsv(String text) {
  final seen = <String>{};
  final out = <ProxyIp>[];
  for (final row in parseSpeedCsvRows(text)) {
    if (!seen.add(row.key)) continue;
    out.add(ProxyIp(row.ip, row.port));
  }
  return out;
}

/// 序列化成与原版 `ProxyIpRepository.toCsv` 一致的 4 列 CSV。
///
/// Latency/Speed 固定写 `0` / `0.00`：proxyip 列表本身不带测速结果，
/// 但格式必须和原版一致，否则把文件导回原版会被判为非法行。
String toProxyIpCsv(List<ProxyIp> list) => toSpeedCsvText(<SpeedCsvRow>[
      for (final item in list)
        SpeedCsvRow(ip: item.ip, port: item.port, latencyMs: 0, speedMib: 0),
    ]);

// ---------------------------------------------------------------------------
// 使用状态（对应原版 proxyip-state.json）
// ---------------------------------------------------------------------------

/// 单个 proxyip 的使用统计。字段与原版 `ProxyIpStat` 一一对应。
class ProxyIpStat {
  const ProxyIpStat({
    this.ok = 0,
    this.fail = 0,
    this.lastOkAt = 0,
    this.lastFailAt = 0,
  });

  final int ok;
  final int fail;
  final int lastOkAt;
  final int lastFailAt;

  ProxyIpStat copyWith({int? ok, int? fail, int? lastOkAt, int? lastFailAt}) =>
      ProxyIpStat(
        ok: ok ?? this.ok,
        fail: fail ?? this.fail,
        lastOkAt: lastOkAt ?? this.lastOkAt,
        lastFailAt: lastFailAt ?? this.lastFailAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'fail': fail,
        'lastOkAt': lastOkAt,
        'lastFailAt': lastFailAt,
      };

  static ProxyIpStat fromJson(Map<String, dynamic> json) => ProxyIpStat(
        ok: (json['ok'] as num?)?.toInt() ?? 0,
        fail: (json['fail'] as num?)?.toInt() ?? 0,
        lastOkAt: (json['lastOkAt'] as num?)?.toInt() ?? 0,
        lastFailAt: (json['lastFailAt'] as num?)?.toInt() ?? 0,
      );
}

/// 全部 proxyip 的使用状态 + 上次成功的那个（原版 `ProxyIpStateFile`）。
class ProxyIpState {
  const ProxyIpState({
    this.stats = const <String, ProxyIpStat>{},
    this.workingKey = '',
  });

  final Map<String, ProxyIpStat> stats;

  /// 上次成功的 `ip:port`，下次优先试它。
  final String workingKey;

  ProxyIpStat statOf(String key) => stats[key] ?? const ProxyIpStat();

  ProxyIpState recordSuccess(String key, {required int nowMs}) => ProxyIpState(
        stats: <String, ProxyIpStat>{
          ...stats,
          key: statOf(key).copyWith(ok: statOf(key).ok + 1, lastOkAt: nowMs),
        },
        workingKey: key,
      );

  /// 失败只累加计数、**不改 workingKey**：一次失败不代表它彻底不能用，
  /// 下一轮排序里它的 fail 升高就会自然排到后面。
  ProxyIpState recordFailure(String key, {required int nowMs}) => ProxyIpState(
        stats: <String, ProxyIpStat>{
          ...stats,
          key: statOf(key)
              .copyWith(fail: statOf(key).fail + 1, lastFailAt: nowMs),
        },
        workingKey: workingKey,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'stats': stats.map((key, value) => MapEntry(key, value.toJson())),
        'workingKey': workingKey,
      };

  static ProxyIpState fromJson(Map<String, dynamic> json) {
    final stats = <String, ProxyIpStat>{};
    final raw = json['stats'];
    if (raw is Map) {
      raw.forEach((key, value) {
        if (key is String && value is Map<String, dynamic>) {
          stats[key] = ProxyIpStat.fromJson(value);
        }
      });
    }
    return ProxyIpState(
      stats: stats,
      workingKey: (json['workingKey'] as String?) ?? '',
    );
  }

  String encode() => jsonEncode(toJson());

  /// 坏文件当作「没有状态」处理：抓取不该因为一个状态文件而失败。
  static ProxyIpState decode(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return fromJson(decoded);
    } on Object {
      // 忽略，返回空状态
    }
    return const ProxyIpState();
  }
}

/// 决定「先用哪条」：**失败少的优先 → 最近成功的优先**，
/// 并把上次成功的 [ProxyIpState.workingKey] 前移（仅当它没有失败记录）。
///
/// 排序主口径与原版 `ProxyIpRepository.ordered` 一致
/// （`compareBy fail` → `thenByDescending lastOkAt`）；
/// workingKey 前移是「用户上次能用的那条，这次先试它」的落地，
/// 但**刚失败过的 workingKey 不再前移** —— 否则每次抓取都先撞同一堵墙。
List<ProxyIp> orderProxyIps(List<ProxyIp> list, ProxyIpState state) {
  final sorted = List<ProxyIp>.of(list)
    ..sort((a, b) {
      final sa = state.statOf(a.key);
      final sb = state.statOf(b.key);
      final byFail = sa.fail.compareTo(sb.fail);
      if (byFail != 0) return byFail;
      return sb.lastOkAt.compareTo(sa.lastOkAt);
    });

  final working = state.workingKey;
  if (working.isEmpty) return sorted;
  final index = sorted.indexWhere((item) => item.key == working);
  if (index <= 0) return sorted;
  if (state.statOf(working).fail > 0) return sorted;

  final first = sorted.removeAt(index);
  return <ProxyIp>[first, ...sorted];
}
