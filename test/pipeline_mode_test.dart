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
    // 延迟阶段多了一个 clientPool 参数：延迟与速度必须共用同一套
    // 「真的能用」的判定（见下一个 test），池子是这条链路的前提。
    expect(go, contains('runLatencyStage(ctx, targets, clientPool, false)'),
        reason: '只延迟模式必须传 false（否则默认 200ms 阈值会误杀大批候选）');
    expect(go, contains('runLatencyStage(ctx, ipsToTest, clientPool, true)'),
        reason: '速度/一键模式保留阈值筛选');
    expect(go, contains('case applyThreshold && cfg.MaxLatency > 0'),
        reason: '阈值判定必须受开关控制');
  });

  // 真实事故（v1.0.19）：延迟阶段只做 TCP 直连握手，速度阶段却要求
  // TLS + HTTP 全通。于是「TCP 通但 TLS/SNI 不通」的候选在延迟阶段算"可用"，
  // 到速度阶段整批失败 —— 用户看到「延迟有数、一测速全挂」或「全部失败」。
  // 现在两个阶段共用 ClientPool 的 client，口径统一：响应头没拿到就不算可用。
  test('延迟测试走 HTTP 客户端：TCP + TLS + 响应头全通才算可用', () {
    final go = File('engine/pipeline.go').readAsStringSync();

    expect(go, contains('func measureClientLatency('),
        reason: '延迟测量必须经 ClientPool 的 client 发真实请求');
    expect(go, isNot(contains('func measureTCPLatency(')),
        reason: '裸 TCP 握手判定已废弃，别悄悄复活');
    expect(go, contains('clientPool.NewClient(result.IP, port)'),
        reason: '每条候选都要绑定自己的 ip:port 建 client');
    expect(go, contains('measureClientLatency(ctx, client, probeURL)'),
        reason: 'runLatencyStage 必须调用新测量函数');
    expect(go, contains('http.MethodHead'),
        reason: '优先 HEAD：测延迟不该把测速文件拉下来');
    expect(go, contains('func describeLatencyError('),
        reason: '失败必须给可读 Reason（超时 / SNI 不匹配 / TLS 不受信任…）');
    // 只延迟模式只是「不按阈值淘汰」，跑不通的仍要失败。
    expect(go, contains('case out.Latency < 0:'),
        reason: '只延迟模式仍需把跑不通的判为失败');
  });

  // 真实事故：用户报「三个按钮全部失败」，根因是配了测速代理但代理没起来 ——
  // 所有目标一律超时，用户从结果里完全看不出是代理的锅。
  // 所以：开测前必须先探一次代理端口，探不通立刻 exit 2，不许伪装成「所有节点都失败」。
  test('测速代理不可用时：开测前探测并以 exit 2 明确报错', () {
    final go = File('engine/pipeline.go').readAsStringSync();

    expect(go, contains('func probeProxy('),
        reason: '缺了开测前的代理可达性探测');
    final mainIdx = go.indexOf('func main() {');
    expect(mainIdx, greaterThan(-1));
    final body = go.substring(mainIdx);
    final probeAt = body.indexOf('probeProxy(ctx, proxyURL.Host)');
    expect(probeAt, greaterThan(-1), reason: 'main 里必须先探代理');
    // 探测失败 → 说人话 + exit 2，且发生在任何模式分支之前。
    final tail = body.substring(probeAt);
    final failBlock = tail.substring(0, 400);
    expect(failBlock, contains('测速代理不可用'));
    expect(failBlock, contains('os.Exit(2)'),
        reason: '环境问题用 exit 2，别和「无可用结果 = exit 1」混在一起');
    final firstMode = body.indexOf('if *onlySpeed {');
    expect(firstMode, greaterThan(probeAt), reason: '代理探测必须早于所有模式分支');

    // 代理链路上的失败要能分级写进 Reason，而不是一句「i/o timeout」。
    expect(go, contains('type proxyDialError struct'),
        reason: '代理侧失败要单独包一层，才能区分「代理挂了」和「节点挂了」');
    expect(go, contains('func describeProxyReason('));
    expect(go, contains('代理隧道失败'));
  });

  // 用户报「全部失败」时，第一件事是看生效配置对不对（是不是走了代理、
  // 测速地址是不是空的、超时是不是太短）。所以启动必须打一行紧凑摘要。
  test('启动打印生效配置摘要（代理 / 测速地址 / 三个超时）', () {
    final go = File('engine/pipeline.go').readAsStringSync();

    expect(go, contains('func logEffectiveConfig()'));
    expect(go, contains('生效配置'));
    final idx = go.indexOf('func logEffectiveConfig()');
    final tail = go.substring(idx);
    final nextFunc = tail.indexOf('\nfunc ');
    final body = nextFunc < 0 ? tail : tail.substring(0, nextFunc);
    for (final key in [
      '测速代理=',
      '测速地址=',
      'dialTimeout=',
      'downloadTimeout=',
      'maxLatency=',
    ]) {
      expect(body, contains(key), reason: '配置摘要缺少 $key');
    }
    // 摘要必须在 main 里被调用，否则等于没写。
    final mainIdx = go.indexOf('func main() {');
    final mainBody = go.substring(mainIdx);
    final callAt = mainBody.indexOf('logEffectiveConfig()');
    expect(callAt, greaterThan(-1));
    expect(callAt, lessThan(mainBody.indexOf('if *onlySpeed {')));
  });

  // 测速地址空着时两个阶段都没法判「能不能用」，必须当配置错误报出来（exit 2），
  // 而不是让全部目标静默失败、最后只剩一句「没有 IP 通过延迟测试」。
  test('测速地址为空时以 exit 2 明确报错', () {
    final go = File('engine/pipeline.go').readAsStringSync();
    final idx = go.indexOf('strings.TrimSpace(cfg.SpeedTestURL) == ""');
    expect(idx, greaterThan(-1), reason: '缺少 speedTestURL 的空值校验');
    final block = go.substring(idx, idx + 400);
    expect(block, contains('speedTestURL'));
    expect(block, contains('os.Exit(2)'));
  });

  // 默认阈值改 0（不限）之后，一键测试会把所有能连通的目标都送进测速。
  // 候选一多（>10 条）用户会以为卡死，所以进入速度阶段时要给个耗时预期。
  test('进入速度阶段的候选偏多时给出「可先筛一遍」的耗时提示', () {
    final go = File('engine/pipeline.go').readAsStringSync();

    expect(go, contains('func logfSpeedQueueHint('));
    expect(go, contains('可先用「延迟测试」筛一遍再测速'));

    final start = go.indexOf('func runSpeedTest(');
    expect(start, greaterThan(-1));
    final tail = go.substring(start);
    final nextFunc = tail.indexOf('\nfunc ');
    final body = nextFunc < 0 ? tail : tail.substring(0, nextFunc);
    expect(body, contains('logfSpeedQueueHint(len(passedList))'),
        reason: '提示要挂在 runSpeedTest 真正进入速度阶段的位置');
  });

  // 0 = 不限：引擎侧不能再拿 0 去和延迟比（0 会把所有候选都判成「超过阈值」）。
  test('maxLatency=0 时阈值不生效（不限）', () {
    final go = File('engine/pipeline.go').readAsStringSync();
    final idx = go.indexOf('case applyThreshold && cfg.MaxLatency > 0');
    expect(idx, greaterThan(-1),
        reason: '阈值判定必须带 cfg.MaxLatency > 0，否则 0 会变成「全部超过阈值」');
  });

  // 真实缺陷（QA 实测）：reqCtx 的截止时间会被 http.Client.Timeout
  // （ClientPool 里设的 downloadTimeout）盖住，有效超时 = 两者的 min。
  // 用户想把测速调快点、把「下载超时」填成 3~5s 时，延迟探测被静默截断，
  // 日志/Reason 里声明的秒数成了假数字，而且「慢但真能用」的候选又被误杀。
  test('延迟探测超时不被 downloadTimeout 截断（浅拷贝 client）', () {
    final go = File('engine/pipeline.go').readAsStringSync();

    expect(go, contains('probeClient := *client'),
        reason: '浅拷贝 client：Transport 共享，不额外建连');
    expect(go, contains('probeClient.Timeout = timeout'),
        reason: '探测超时必须用延迟自己的声明值，不能沿用 downloadTimeout');
    expect(go, contains('probeClient.Do(req)'));
    // 速度阶段必须仍用池子里的原 client，别被这次改动带跑。
    expect(go, contains('measureDownload(ctx, client, cfg.SpeedTestURL)'),
        reason: '测速阶段的行为与超时口径不能变');
  });

  // 两条「日志/Reason 说的和实际不一致」的修正（QA 实测提出）：
  // 1) 拨号阶段超时（TCP 都没连上）用的预算是 dialTimeout，不是总预算；
  // 2) 桌面端读不到 Android 证书目录是正常分支，不该报「没有根证书」。
  test('失败原因的秒数与真实生效的阶段一致', () {
    final go = File('engine/pipeline.go').readAsStringSync();

    expect(go, contains('func dialTimeoutReason('));
    expect(go, contains('opErr.Op == "dial"'),
        reason: '要靠 net.OpError 的 Op 区分「拨号阶段」与「已连上等响应」');
    expect(go, contains('拨号阶段'));

    expect(go, isNot(contains('系统目录里没读到证书')),
        reason: '桌面端每轮打这行是误导：HTTPS 其实是好的');
    expect(go, contains('sawCertDir'),
        reason: '只有「证书目录存在但没读到证书」才值得提醒');
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
