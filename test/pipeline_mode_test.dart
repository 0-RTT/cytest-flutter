import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 本地测试页的三个按钮 → pipeline 命令行参数的映射。
///
/// `_modeArgs` 是私有静态方法，直接单测要开 `@visibleForTesting` 才能调；
/// 这里沿用 `history_nav_test.dart` 的源码断言先例，把映射钉死。
/// 一旦有人把 `latency` 误接成 `-only-speed`，用户点「延迟测试」会得到速度结果，
/// 这类错误编译期和现有 widget 测试都抓不到。
void main() {
  late String src;
  late String modeArgs;

  setUpAll(() {
    src = File('lib/data/pipeline.dart').readAsStringSync();
    final start = src.indexOf('static List<String> _modeArgs(');
    expect(start, greaterThan(-1), reason: '找不到 _modeArgs，测试本身已失效');
    final end = src.indexOf('static String _stamp()', start);
    expect(end, greaterThan(start));
    modeArgs = src.substring(start, end);
  });

  test('latency → -only-latency + -targets', () {
    final branch = _branch(modeArgs, "case 'latency':");
    expect(branch, contains("'-only-latency'"));
    expect(branch, contains("'-targets'"));
    expect(branch, isNot(contains("'-only-speed'")));
    expect(branch, isNot(contains("'-data'")));
  });

  test('speed → -only-speed + -targets', () {
    final branch = _branch(modeArgs, "case 'speed':");
    expect(branch, contains("'-only-speed'"));
    expect(branch, contains("'-targets'"));
    expect(branch, isNot(contains("'-only-latency'")));
  });

  test('both → 只给 -targets（延迟 + 速度）', () {
    final branch = _branch(modeArgs, "case 'both':");
    expect(branch, contains("'-targets'"));
    expect(branch, isNot(contains("'-only-latency'")));
    expect(branch, isNot(contains("'-only-speed'")));
    expect(branch, isNot(contains("'-data'")));
  });

  test('未知模式回退到 -data（保持旧行为，不静默变成测速）', () {
    final fallback = modeArgs.substring(modeArgs.indexOf('default:'));
    expect(fallback, contains("'-data'"));
  });

  test('Go 引擎确实声明了 -only-latency 并强制要求 -targets', () {
    final go = File('engine/pipeline.go').readAsStringSync();
    expect(go, contains('flag.Bool("only-latency"'));
    // 没有 -targets 时必须报错退出，否则会退化成「没有输入却跑一遍」
    final idx = go.indexOf('if *onlyLatency {');
    expect(idx, greaterThan(-1), reason: '-only-latency 分支缺失');
    final branch = go.substring(idx, idx + 400);
    expect(branch, contains('-targets'));
    expect(branch, contains('os.Exit'));
  });

  test('Go 引擎：测速汇总以「可用结果数」为口径，全失败 → exit 1', () {
    final go = File('engine/pipeline.go').readAsStringSync();

    // 口径来源：reportSpeedResults 复用既有 speedStats 的 ok 计数，
    // ok == 0 即「一次都没有可用结果」→ 返回 false。三种模式共用这一处判定，
    // 所以只测这里就能锁住 -only-speed 与 -targets 全量的退出码语义。
    final start = go.indexOf('func reportSpeedResults(');
    expect(start, greaterThan(-1), reason: 'reportSpeedResults 缺失');
    final tail = go.substring(start);
    final nextFunc = tail.indexOf('\nfunc ');
    final body = nextFunc < 0 ? tail : tail.substring(0, nextFunc);
    expect(body, contains('speedStats(sorted)'),
        reason: '必须复用已有汇总口径（speedStats），不要另造一套');
    expect(body, contains('ok == 0'));
    expect(body, contains('return false'));

    // -only-speed 的判据是「有没有可用结果」，不是「跑没跑过」；
    // 早期实现全失败也 exit 0，正是这里漏判导致的。
    //
    // 这里刻意**不**断言具体的返回约定（`== nil` 还是 `(results, ok)`）：
    // `runLatencyOnly` 已经从「返回 nil」重构成「返回 (results, ok)」，
    // speed 侧随时可能跟进。钉住调用约定会让一次等价重构变成假失败。
    // 真正要钉的是「该分支存在一条通往 exit 1 的路径」。
    final speedIdx = go.indexOf('if *onlySpeed {');
    expect(speedIdx, greaterThan(-1), reason: '-only-speed 分支缺失');
    final speedBranch = go.substring(speedIdx, speedIdx + 900);
    expect(speedBranch, contains('runSpeedOnly(ctx, targets)'));
    expect(speedBranch, contains('os.Exit(1)'));
  });

  // 三模式共用同一个退出码契约：0 条可用结果 → exit 1，但**仍然写 result.csv**。
  // 后半句是 Dart 侧 `pipeline.dart:142-148` 的 partial-CSV 兜底赖以成立的前提 ——
  // 只 exit 1 不写 CSV 的话，App 会抛「没有测出可用结果（引擎退出码 N）」，
  // 用户在「全部节点都不通」这种常见场景下一条明细行都看不到。
  // （该契约在 94dfe5f2 上已用真实二进制逐模式实测确认；此处只能做源码级钉住，
  //  因为本仓库没有 go.mod，跑不了 go test。）
  test('三种模式全失败时都必须在 exit 1 之前把失败明细写进 CSV', () {
    final go = File('engine/pipeline.go').readAsStringSync();

    for (final fn in ['func reportLatencyResults(', 'func reportSpeedResults(']) {
      final start = go.indexOf(fn);
      expect(start, greaterThan(-1), reason: '$fn 缺失');
      final tail = go.substring(start);
      final nextFunc = tail.indexOf('\nfunc ');
      final body = nextFunc < 0 ? tail : tail.substring(0, nextFunc);

      final writeAt = body.indexOf('writeResultCSV(');
      final zeroAt = body.indexOf('ok == 0');
      expect(writeAt, greaterThan(-1), reason: '$fn 必须写 result.csv');
      expect(zeroAt, greaterThan(-1),
          reason: '$fn 必须以「可用结果数」判定成败，不能用「跑没跑过」');
      // 关键顺序：先写盘、再给「0 条可用」的失败判定。
      // 反过来就是「exit 1 了但 CSV 没落盘」，App 侧 partial-CSV 兜底会失效，
      // 用户看到的是「没有测出可用结果（引擎退出码 N）」而不是失败明细。
      expect(zeroAt, greaterThan(writeAt),
          reason: '$fn 里 writeResultCSV 必须早于 ok == 0 的失败返回');
    }
  });

  // `-targets`（一键测试 = 延迟 + 速度）走的是 runSpeedTest，它**不经过**
  // report*Results：延迟阶段一条都没过时，得先补写一份失败明细再 return nil，
  // 上层才会 exit 1 且产物仍在。少了这一步，App 在「全部节点不通」时会抛
  // 「没有测出可用结果（引擎退出码 N）」，而不是展示失败明细列表。
  // 实测证据：BOTH_FAIL → exit 1 / CSV 5 行（表头 + 4 条「延迟测试失败」）。
  test('runSpeedTest 延迟全失败时必须先补写 CSV 再 return nil', () {
    final go = File('engine/pipeline.go').readAsStringSync();
    final start = go.indexOf('func runSpeedTest(');
    expect(start, greaterThan(-1), reason: 'runSpeedTest 缺失');
    final tail = go.substring(start);
    final nextFunc = tail.indexOf('\nfunc ');
    final body = nextFunc < 0 ? tail : tail.substring(0, nextFunc);

    // 坑：runSpeedTest 里有多处 `return nil`（无候选早退 / 延迟全失败 / 其他），
    // 直接 `indexOf('return nil')` 会先命中最前面那处早退，比较必然假失败。
    // 所以先收集全部位置，再判断「补写」落在哪两个 return 之间。
    final nilIdxs = <int>[];
    for (var i = body.indexOf('return nil'); i >= 0;
        i = body.indexOf('return nil', i + 1)) {
      nilIdxs.add(i);
    }
    expect(nilIdxs.length, greaterThanOrEqualTo(2),
        reason: 'runSpeedTest 控制流变了，请重新审视本断言');

    final writeAt = body.indexOf('writeLatencyFailureCSV(');
    expect(writeAt, greaterThan(-1),
        reason: 'runSpeedTest 必须在延迟全失败时补写失败明细');

    // 补写要落在「无候选早退」之后（否则是死代码）……
    expect(writeAt, greaterThan(nilIdxs[0]),
        reason: 'writeLatencyFailureCSV 不能在无候选早退之前');
    // ……并且早于紧随其后的那个 `return nil`（否则等于没写就退出了）。
    expect(writeAt, lessThan(nilIdxs[1]),
        reason: 'writeLatencyFailureCSV 必须早于延迟全失败的 return nil（否则是死代码）');
  });

  // 真实事故：maxLatency 默认 200ms，若「延迟测试」也按它筛，跨境候选
  // （普遍 200-400ms）会被整批标成「超过阈值」，用户看到的就是「全部失败」。
  // 延迟测试的语义是「测出每条的真实延迟」，不是「筛出达标的」。
  test('延迟测试不按 maxLatency 筛选，一键测试保留筛选', () {
    final go = File('engine/pipeline.go').readAsStringSync();

    expect(go, contains('applyThreshold bool'),
        reason: 'runLatencyStage 必须有阈值开关');
    expect(go, contains('runLatencyStage(ctx, targets, false)'),
        reason: '只延迟模式必须传 false（否则默认 200ms 阈值会误杀大批候选）');
    expect(go, contains('runLatencyStage(ctx, ipsToTest, true)'),
        reason: '速度/一键模式保留阈值筛选');
    expect(go, contains('case applyThreshold && cfg.MaxLatency > 0'),
        reason: '阈值判定必须受开关控制');
  });
}

/// 取 `case 'x':` 到下一个 `case`/`default:` 之间的源码片段。
String _branch(String src, String marker) {
  final start = src.indexOf(marker);
  expect(start, greaterThan(-1), reason: '缺少分支 $marker');
  final rest = src.substring(start + marker.length);
  final next = RegExp(r'(case\s+|default\s*:)').firstMatch(rest);
  final body = next == null ? rest : rest.substring(0, next.start);
  return body;
}
