import 'node_template.dart';
import 'vless.dart';

/// 推送内容生成失败（可展示给用户的中文原因）。
class PublishException implements Exception {
  const PublishException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一条 vless 模板 × 选中节点生成的全部产物。
class PublishBundle {
  const PublishBundle({
    required this.links,
    required this.subscription,
    required this.yaml,
  });

  /// 替换 ip:port 后的 vless 链接（每行一条）。
  final List<String> links;

  /// base64 订阅正文。
  final String subscription;

  /// mihomo YAML 配置。
  final String yaml;
}

/// 把模板里的 `host:port` 槽位逐个替换成选中的 `ip:port`，
/// 再生成 base64 订阅与 mihomo YAML。纯函数，便于单测。
PublishBundle buildPublish({
  required String template,
  required List<String> targets,
}) {
  final t = template.trim();
  if (t.isEmpty) throw const PublishException('先填入一条 vless 模板链接');

  final v = Vless.tryParse(t);
  if (v == null) {
    throw const PublishException('vless 链接格式不对（需要 vless://uuid@host:port?...）');
  }
  if (!hasSlot(t)) {
    throw const PublishException('这条链接没有可替换的 host:port 槽位');
  }
  if (targets.isEmpty) throw const PublishException('没有选中的节点');

  final links = expandTemplate(t, targets);
  if (links.isEmpty) throw const PublishException('没有生成任何链接');

  return PublishBundle(
    links: links,
    subscription: subscription(links),
    // 与 Kotlin MihomoYaml.build 同构：逐条解析已展开的链接，
    // 节点名取各自的 #备注，而不是用模板的序号拼 IP。
    yaml: buildMihomoYaml(links),
  );
}
