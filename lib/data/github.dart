import 'dart:convert';
import 'dart:io';

/// 把内容写到 GitHub 仓库文件（存在则更新）。语义对齐桌面端 pushGithub。
class GitHub {
  GitHub._();

  static Future<String> push({
    required String token,
    required String repo,
    required String path,
    required String content,

    /// 非空时把请求走本机 VLESS 代理（`127.0.0.1:port`）；空 = 直连。
    /// 与 Kotlin `GitHubClient.upload(config, ..., proxy)` 的 `proxy` 参数同义。
    int? proxyPort,
  }) async {
    if (token.trim().isEmpty) throw Exception('先在设置里填 GitHub token');
    if (!repo.contains('/')) throw Exception('仓库格式应为 owner/name');
    final target = path.trim().isEmpty ? 'cytest-sub.txt' : path.trim();
    if (content.isEmpty) throw Exception('内容为空');

    final endpoint = Uri.parse('https://api.github.com/repos/$repo/contents/$target');
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
