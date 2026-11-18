import 'link_test.dart';

/// 链路测速结果的排序维度。
enum LinkResultSort { latency, speed }

extension LinkResultSortLabel on LinkResultSort {
  /// 按钮文案。
  String get label => switch (this) {
        LinkResultSort.latency => '按延迟',
        LinkResultSort.speed => '按速度',
      };
}

/// 纯函数排序：把 [results] 复制一份后按 [sort] 排序返回。
///
/// 规则（与 UI 面板 `LinkTestPanel` 的口径保持一致）：
/// - 按延迟：已知延迟升序，**未知/失败项永远排末尾**；
/// - 按速度：只有测出速度（`hasSpeed`）的参与前段并倒序，失败项与未测项排末尾；
/// - 同值保持原有相对顺序（`List.sort` 不稳定，这里用带下标的比较兜住）。
List<LinkTestResult> sortLinkResults(
  List<LinkTestResult> results, {
  required LinkResultSort sort,
}) {
  final indexed = <(int, LinkTestResult)>[
    for (var i = 0; i < results.length; i++) (i, results[i]),
  ];

  indexed.sort((a, b) {
    final cmp = _compare(a.$2, b.$2, sort);
    if (cmp != 0) return cmp;
    return a.$1.compareTo(b.$1);
  });

  return <LinkTestResult>[for (final entry in indexed) entry.$2];
}

int _compare(LinkTestResult a, LinkTestResult b, LinkResultSort sort) {
  if (sort == LinkResultSort.speed) {
    final av = a.hasSpeed ? (a.speedMib ?? 0) : -1.0;
    final bv = b.hasSpeed ? (b.speedMib ?? 0) : -1.0;
    if (av < 0 && bv >= 0) return 1;
    if (bv < 0 && av >= 0) return -1;
    return bv.compareTo(av);
  }

  final av = a.latencyKnown ? a.latencyMs : 0x7FFFFFFF;
  final bv = b.latencyKnown ? b.latencyMs : 0x7FFFFFFF;
  return av.compareTo(bv);
}
