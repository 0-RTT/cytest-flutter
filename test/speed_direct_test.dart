import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「优选 IP 测速必须直连」这条契约的回归测试。
///
/// 背景（2026-11-18 真实事故）：设置页曾有一个「测速代理」输入框，值被写进
/// pipeline 的 `httpProxy`。用户按自己的理解填了 `101.34.32.230:22304`
/// （实测：明文 CONNECT → Cloudflare 400；SOCKS5 → invalid version；
/// TLS 上做 CONNECT → TLS alert 40，即「按 SNI 分流的 TLS 入口」，
/// 根本不是 HTTP 代理），于是 553 条候选每一条都在 dialTunnelViaProxy 处
/// 拿到 400，结果页 100% 显示「代理隧道失败」，一键测试彻底失效。
///
/// 引擎 config.json 的字段集里没有 httpProxy，
/// `LocalSpeedRunner.startProcess()` 的参数只有
/// `-only-speed -targets -config -result`，引擎侧全量 grep `httpProxy`
/// 零命中 —— 优选 IP 测速是**无条件直连**的。
///
/// 所以这里钉住三件事：
/// 1. 交给引擎的 config.json 不含 httpProxy；
/// 2. 设置页不再提供该输入项，也不再往 settings 写；
/// 3. lib/ 下除了 settings.dart 的兼容性声明外，没有第二处碰它。
void main() {
  late String pipelineSrc;
  late String settingsPageSrc;
  late String settingsSrc;

  setUpAll(() {
    pipelineSrc = File('lib/data/pipeline.dart').readAsStringSync();
    settingsPageSrc = File('lib/ui/pages/settings_page.dart').readAsStringSync();
    settingsSrc = File('lib/core/settings.dart').readAsStringSync();
  });

  /// 截出 `_configJson` 的函数体（文档注释在签名之前，不会被截进来）。
  String configJsonBody() {
    final start = pipelineSrc.indexOf('static String _configJson(');
    expect(start, greaterThan(-1), reason: '找不到 _configJson，本测试已失效');
    final end = pipelineSrc.indexOf('static Future<List<Map<String, String>>> _readCsv(');
    expect(end, greaterThan(start), reason: '_configJson 之后找不到 _readCsv');
    return pipelineSrc.substring(start, end);
  }

  test('交给引擎的 config.json 不含 httpProxy（测速直连）', () {
    final body = configJsonBody();
    expect(body, contains("'speedTestURL'"), reason: 'config 必须仍带测速地址');
    expect(body, isNot(contains('httpProxy')),
        reason: '一旦写回 httpProxy，非 HTTP 代理的地址会让全部候选报「代理隧道失败」');
  });

  test('config.json 的字段集与引擎约定一致', () {
    final body = configJsonBody();
    // 引擎 configJson 的全部字段（口径见文件头注释）。
    for (final key in [
      'speedTestURL',
      'dialTimeout',
      'downloadTimeout',
      'maxLatencyConcurrency',
      'maxSpeedConcurrency',
      'maxLatency',
      'MaxSha1Concurrency',
    ]) {
      expect(body, contains("'$key'"), reason: '缺少同名字段 $key');
    }
  });

  test('设置页不再提供「测速代理」输入项', () {
    expect(settingsPageSrc, isNot(contains("_text('测速代理'")),
        reason: '输入项必须移除，否则用户填错地址又把整轮测试打成假失败');
    expect(settingsPageSrc, isNot(contains('s.httpProxy')),
        reason: '设置页不该再读写已停用的字段');
  });

  test('lib/ 下除 settings.dart 的兼容声明外，没有第二处引用 httpProxy', () {
    // 只统计「代码行」：注释里提到 httpProxy 是合理的（本仓库多处文档在解释
    // 为什么不能用它），不能算违规。所以先剥掉 // /// /* * 开头的行。
    final hits = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('settings.dart')) continue;
      final codeLines = entity
          .readAsStringSync()
          .split('\n')
          .map((l) => l.trim())
          .where((l) =>
              l.isNotEmpty &&
              !l.startsWith('//') &&
              !l.startsWith('*') &&
              !l.startsWith('/*'))
          .where((l) => l.contains('httpProxy'));
      if (codeLines.isNotEmpty) {
        hits.add('${entity.path}（${codeLines.length} 行）');
      }
    }
    expect(hits, isEmpty,
        reason: '这些文件仍在代码中引用已停用的测速代理：${hits.join('、')}');
  });

  test('settings.dart 保留字段以兼容旧配置/备份，并注明已停用', () {
    expect(settingsSrc, contains('String httpProxy;'),
        reason: '删字段会让旧 settings.json / 备份导入时报「取值失败」，先保留声明');
    final idx = settingsSrc.indexOf('String httpProxy;');
    expect(idx, greaterThan(-1));

    // 向上回溯收集紧邻的连续 /// 注释块（遇到普通代码行即停）。
    final docLines = <String>[];
    for (final raw in settingsSrc.substring(0, idx).split('\n').reversed) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      if (!t.startsWith('///')) break;
      docLines.add(t);
    }
    final doc = docLines.join('\n');
    expect(doc, isNotEmpty, reason: '字段上方必须有说明，否则下一个人会把它接回 UI');
    expect(doc, contains('已停用'),
        reason: '字段留着却没有任何标注，下一个人必然又把 UI 接回来');
    expect(doc, contains('直连'));
  });
}
