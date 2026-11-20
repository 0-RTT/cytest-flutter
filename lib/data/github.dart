import 'dart:convert';
import 'dart:io';

/// 把用户填写的各种仓库写法规范化为 `owner/repo`。
///
/// 支持的输入形式（都得到 `0-RTT/sub`）：
///   * `https://github.com/0-RTT/sub`
///   * `https://github.com/0-RTT/sub.git`
///   * `http://github.com/0-RTT/sub/`
///   * `github.com/0-RTT/sub`
///   * `0-RTT/sub`（已规范化的原样返回）
///
/// 同时容忍：协议头、`www.`/`api.github.com` 主机名、尾部斜杠、`.git` 后缀、
/// URL 的 query/fragment、以及 `git@github.com:owner/repo.git` 这种 scp 写法。
///
/// 无法解析（缺 owner 或 repo）时返回空串 —— 调用方据此提示用户，
/// 不会把半个地址拼进 API URL。
String parseRepoSlug(String input) {
  var s = input.trim();
  if (s.isEmpty) return '';

  // 1) 去掉协议头：https:// http:// git:// ssh:// ...
  final scheme = s.indexOf('://');
  if (scheme >= 0) s = s.substring(scheme + 3);

  // 2) scp 写法 git@github.com:owner/repo.git —— 去掉 git@ 后把分隔的 ':' 换成 '/'
  if (s.toLowerCase().startsWith('git@')) {
    s = s.substring(4);
    final colon = s.indexOf(':');
    final slash = s.indexOf('/');
    if (colon >= 0 && (slash < 0 || colon < slash)) {
      s = s.replaceRange(colon, colon + 1, '/');
    }
  }

  // 3) query / fragment 一律丢弃（可能带 ?ref=main 之类）
  for (final sep in const ['?', '#']) {
    final i = s.indexOf(sep);
    if (i >= 0) s = s.substring(0, i);
  }

  // 4) 去掉主机名（大小写不敏感），按最长前缀优先匹配
  for (final host in const [
    'api.github.com/repos',
    'api.github.com',
    'www.github.com',
    'github.com',
  ]) {
    if (s.toLowerCase().startsWith(host)) {
      s = s.substring(host.length);
      break;
    }
  }

  // 5) 首尾斜杠、尾部 .git 后缀
  s = s.replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
  if (s.toLowerCase().endsWith('.git')) {
    s = s.substring(0, s.length - 4);
  }
  s = s.replaceAll(RegExp(r'/+$'), '');

  // 6) 取前两段：多余路径（如 /tree/main）忽略
  final segments =
      s.split('/').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  if (segments.length < 2) return '';

  final owner = segments[0];
  var repo = segments[1];
  if (repo.toLowerCase().endsWith('.git')) {
    repo = repo.substring(0, repo.length - 4);
  }
  if (owner.isEmpty || repo.isEmpty) return '';

  return '$owner/$repo';
}

/// 把内容写到 GitHub 仓库文件（存在则更新）。语义对齐桌面端 pushGithub。
class GitHub {
  GitHub._();

  static Future<String> push({
    required String token,
    required String repo,
    required String path,
    required String content,

    /// 非空时把请求走本机 VLESS 代理（`127.0.0.1:port`）；空 = 直连。
    /// 走代理时传本机端口；null = 直连。
    int? proxyPort,
  }) async {
    if (token.trim().isEmpty) throw Exception('先在设置里填 GitHub token');
    // 允许用户直接粘仓库网页地址，这里统一规范化成 owner/repo。
    final slug = parseRepoSlug(repo);
    if (slug.isEmpty) {
      throw Exception('GitHub 仓库地址格式不对，应形如 https://github.com/owner/repo');
    }
    final target = path.trim().isEmpty ? 'cytest-sub.txt' : path.trim();
    if (content.isEmpty) throw Exception('内容为空');

    final endpoint =
        Uri.parse('https://api.github.com/repos/$slug/contents/$target');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    if (proxyPort != null) {
      client.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
    }

    String sha = '';
    try {
      final req = await client.getUrl(endpoint);
      req.headers.set('Authorization', 'Bearer $token');
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'cytest');
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode == 200) {
        final meta = jsonDecode(body) as Map<String, dynamic>;
        sha = meta['sha'] as String? ?? '';
      }
    } catch (_) {
      // 文件不存在或网络异常，继续尝试创建
    }

    final payload = <String, dynamic>{
      'message': 'cytest: 更新 $target',
      'content': base64Encode(utf8.encode(content)),
      if (sha.isNotEmpty) 'sha': sha,
    };

    final put = await client.putUrl(endpoint);
    put.headers.set('Authorization', 'Bearer $token');
    put.headers.set('Accept', 'application/vnd.github+json');
    put.headers.set('Content-Type', 'application/json');
    put.headers.set('User-Agent', 'cytest');
    put.add(utf8.encode(jsonEncode(payload)));

    final resp = await put.close();
    final body = await resp.transform(utf8.decoder).join();
    client.close();

    if (resp.statusCode >= 300) {
      final snippet = body.length > 300 ? body.substring(0, 300) : body;
      throw Exception('HTTP ${resp.statusCode}：$snippet');
    }
    return target;
  }
}
