# -*- coding: utf-8 -*-
"""Dart 侧：私钥文件选择入口 + 设置页「选择」按钮。"""
import io

# ---------- 1) file_pick.dart ----------
p = 'lib/core/file_pick.dart'
s = io.open(p, encoding='utf-8').read()
s = s.replace("""String _humanize(PlatformException e) {""",
"""/// 选一个 SSH 私钥文件。
///
/// 与 [pickTextFile] 分开的原因：那个把 MIME 限定在 text/csv 一类，而私钥常常
/// **没有后缀**（id_rsa / id_ed25519），SAF 报不出类型 → 在选择器里直接变灰。
/// 这里用 `*/*` 不做过滤，并且由原生侧把内容复制到应用目录后返回**副本路径**
/// （`content://` 不能交给 dartssh2 当文件路径，也不能重复读）。
///
/// 返回 `null` = 用户取消；抛 [FilePickException] = 选择或复制失败。
Future<String?> pickKeyFile() async {
  try {
    return await _channel.invokeMethod<String>('pickKeyFile');
  } on PlatformException catch (e) {
    throw FilePickException(_humanize(e));
  } on MissingPluginException {
    throw const FilePickException('当前平台没有实现文件选择器（仅 Android 支持）');
  }
}

String _humanize(PlatformException e) {""", 1)
io.open(p, 'w', encoding='utf-8').write(s)

# ---------- 2) settings_page.dart ----------
p = 'lib/ui/pages/settings_page.dart'
s = io.open(p, encoding='utf-8').read()

# _text 支持尾部按钮
old_text = """  Widget _text(String label, TextEditingController c,
          {String? hint, bool obscure = false}) =>
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: TextField(
          controller: c,
          obscureText: obscure,
          style: const TextStyle(fontSize: 13),
          decoration: _decoration(label: label, hint: hint),
        ),
      );"""
new_text = """  Widget _text(String label, TextEditingController c,
          {String? hint, bool obscure = false, VoidCallback? onPick, String? pickTooltip}) =>
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: TextField(
          controller: c,
          obscureText: obscure,
          style: const TextStyle(fontSize: 13),
          decoration: _decoration(label: label, hint: hint).copyWith(
            // 有些字段（私钥路径）没法手输一个真实路径：给个系统选择器入口。
            suffixIcon: onPick == null
                ? null
                : IconButton(
                    tooltip: pickTooltip ?? '选择文件',
                    icon: const Icon(Icons.folder_open, size: 18),
                    onPressed: onPick,
                  ),
          ),
        ),
      );"""
assert old_text in s
s = s.replace(old_text, new_text, 1)

# 远程分组：私钥路径加选择按钮
old_row = """          _text('私钥路径', _remoteKey, hint: '留空则用密码'),"""
new_row = """          _text('私钥路径', _remoteKey,
              hint: '留空则用密码',
              onPick: _pickKeyFile,
              pickTooltip: '选择私钥文件'),
          _caption('点右侧文件夹选私钥：无后缀的 id_rsa 也能选，'
              '会复制一份到应用目录（原文件可删）。'),"""
assert old_row in s
s = s.replace(old_row, new_row, 1)

# 选择方法：插在 _save 之前
anchor = "  Future<void> _save() async {"
method = """  /// 选私钥文件：选中后把「应用目录里的副本路径」填进输入框。
  ///
  /// 只填路径、不碰其它字段：这个输入框本来就只是「一个路径字符串」，
  /// 复制动作由原生侧完成，Dart 这边不需要读文件内容。
  Future<void> _pickKeyFile() async {
    try {
      final path = await pickKeyFile();
      if (path == null || path.isEmpty) return; // 用户取消
      if (!mounted) return;
      setState(() => _remoteKey.text = path); // 触发去抖自动保存
    } on FilePickException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _save() async {"""
assert anchor in s
s = s.replace(anchor, method, 1)

io.open(p, 'w', encoding='utf-8').write(s)
print('ok')
