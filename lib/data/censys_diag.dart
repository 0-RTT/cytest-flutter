import 'vless.dart';

/// 一次失败抓取的出口诊断串（日志粒度：出口 IP / 状态码 / 错误类别）。
///
/// 只看到「挑战未过」无法判断是出口 IP 脏、回源 path 没换成功、还是 Host/SNI
/// 配错。把这次实际用的线路与替换后的回源 path 打出来，才能远程排障。
String censysRouteDiagnosis(
  Vless? v,
  ProxyIp? proxy,
) {
  if (v == null) return '  线路：未配置 vless（直连）';
  final before = v.wsPath;
  // path 替换实际发生在 Xray 的 buildXrayConfig；这里复算一份仅用于展示。
  final shownPath = proxy != null && pathProxyIp(before) != null
      ? replacePathIp(before, proxy)
      : before;
  final sni = v.sni.isNotEmpty ? v.sni : v.wsHost;
  return '  回源 ${before.isEmpty ? "（空）" : before} → '
      '${shownPath.isEmpty ? "（空）" : shownPath}\n'
      '  线路 ${v.host}:${v.port} · Host ${v.wsHost.isEmpty ? "（空）" : v.wsHost}'
      ' · SNI ${sni.isEmpty ? "（空，用 Host 兜底）" : sni}'
      '${v.alpn.isNotEmpty ? ' · alpn ${v.alpn}' : ''}';
}
