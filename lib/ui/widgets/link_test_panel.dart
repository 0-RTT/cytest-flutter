import 'package:flutter/material.dart';

import '../../data/link_test.dart';

/// 结果排序维度。
enum LinkSort { speed, latency }

/// 结果行状态：「未测」永远排最后，不论按哪个维度排序。
extension LinkSortLabel on LinkSort {
  String get label => switch (this) {
        LinkSort.speed => '按速度',
        LinkSort.latency => '按延迟',
      };
}

/// 测速面板：进度 / 取消 / 结果表（排序、只看失败）。
///
/// 纯展示组件：只吃 [results] 与 [stage]，不读 AppState —— 这样才能用 widget test
/// 直接断言「未测不显示 0」这类硬规则（D2 的命门）。
class LinkTestPanel extends StatefulWidget {
  const LinkTestPanel({
    super.key,
    required this.results,
    required this.stage,
    required this.running,
    required this.onCancel,
  });

  /// 当前结果（只读快照）。
  final List<LinkTestResult> results;

  /// 阶段文字（准备中 / 延迟探测 / 速度探测 / 完成 / 已取消）。
  final String stage;

  /// 是否正在跑（决定「取消」按钮可用性）。
  final bool running;

  /// 取消回调（调 `AppState.cancelLinkTest()`）。
  final VoidCallback onCancel;

  @override
  State<LinkTestPanel> createState() => _LinkTestPanelState();
}

class _LinkTestPanelState extends State<LinkTestPanel> {
  LinkSort _sort = LinkSort.speed;
  bool _failuresOnly = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _visibleRows();
    final done = widget.results.where(_isTerminal).length;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('链路测速', style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Text(
                  '$done / ${widget.results.length}',
                  style: theme.textTheme.labelSmall,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.stage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (widget.running)
                  TextButton(
                    onPressed: widget.onCancel,
                    child: Text(
                      '取消',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                SegmentedButton<LinkSort>(
                  segments: const [
                    ButtonSegment(value: LinkSort.speed, label: Text('按速度')),
                    ButtonSegment(value: LinkSort.latency, label: Text('按延迟')),
                  ],
                  selected: <LinkSort>{_sort},
                  onSelectionChanged: (s) => setState(() => _sort = s.first),
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const Spacer(),
                FilterChip(
                  label: const Text('只看失败'),
                  selected: _failuresOnly,
                  onSelected: (v) => setState(() => _failuresOnly = v),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  widget.results.isEmpty ? '还没有结果' : '没有符合条件的条目',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              for (var i = 0; i < visible.length; i++)
                _row(theme, i, visible[i]),
          ],
        ),
      ),
    );
  }

  Widget _row(ThemeData theme, int index, LinkTestResult result) {
    final failed = result.error != null || result.state == ProbeState.cancelled;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: SizedBox(
        width: 22,
        child: Text('${index + 1}', style: theme.textTheme.labelSmall),
      ),
      // 长地址 / 长备注会顶破 ListTile，单行省略
      title: Text(
        result.host.isEmpty ? result.name : '${result.host}:${result.port}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: 'monospace',
          // Android 的 monospace 不含完整中文字形，缺 fallback 中文会变方块
          fontFamilyFallback: <String>['sans-serif'],
          fontSize: 12.5,
        ),
      ),
      subtitle: result.error == null
          ? null
          : Text(
              result.error!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 11),
            ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _speedText(result),
            style: TextStyle(
              fontSize: 12,
              color: result.hasSpeed
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            _latencyText(result),
            style: TextStyle(fontSize: 11, color: theme.hintColor),
          ),
        ],
      ),
      isThreeLine: failed && result.error != null,
    );
  }

  /// 速度列文案（**D2 命门**：未测必须写「未测」，绝不显示 `0.00 MiB/s`）。
  String _speedText(LinkTestResult result) {
    if (result.state == ProbeState.cancelled) return '已取消';
    if (result.error != null) return '失败';
    final speed = result.speedMib;
    if (speed == null || !result.hasSpeed) return '未测';
    return '${speed.toStringAsFixed(2)} MiB/s';
  }

  /// 延迟列文案：-1（未知）显示「—」，不要显示 `-1 ms`。
  String _latencyText(LinkTestResult result) =>
      result.latencyKnown ? '${result.latencyMs} ms' : '—';

  bool _isTerminal(LinkTestResult result) =>
      result.state == ProbeState.done ||
      result.state == ProbeState.failed ||
      result.state == ProbeState.cancelled;

  /// 排序 + 过滤：未知值（未测 / 未探测）永远排最后。
  List<LinkTestResult> _visibleRows() {
    final rows = widget.results
        .where((r) =>
            !_failuresOnly ||
            r.error != null ||
            r.state == ProbeState.cancelled)
        .toList(growable: false);

    int compare(LinkTestResult a, LinkTestResult b) {
      if (_sort == LinkSort.speed) {
        final av = a.hasSpeed ? (a.speedMib ?? 0) : -1.0;
        final bv = b.hasSpeed ? (b.speedMib ?? 0) : -1.0;
        // 未测（-1）排最后
        if (av < 0 && bv >= 0) return 1;
        if (bv < 0 && av >= 0) return -1;
        return bv.compareTo(av);
      }
      final av = a.latencyKnown ? a.latencyMs : 0x7FFFFFFF;
      final bv = b.latencyKnown ? b.latencyMs : 0x7FFFFFFF;
      return av.compareTo(bv);
    }

    final sorted = List<LinkTestResult>.of(rows)..sort(compare);
    return sorted;
  }
}
