/// 国际化域名（IDN）→ ASCII（punycode）转换。
///
/// 为什么必须自己做：`dart:io` 的 `Uri` / `HttpClient` **不做** IDNA 转换。
/// 默认测速地址 `https://е.eu.org/300.zip` 里的 `е` 是西里尔字母 U+0435，
/// 直接交给 `HttpClient` 时会用 ISO-8859-1 编码主机名 → 要么抛错，
/// 要么发出一个根本不存在的主机名。最坏的后果不是「速度测错」，而是
/// **每个节点都失败，用户误以为线路全挂了**（设计 §9 R4）。
///
/// 决策 K1：自实现 RFC 3492 punycode，**零依赖**；不支持的字符显式抛
/// [UnsupportedIdnException]，绝不静默产出错误结果。
///
/// 本文件不依赖 Flutter，可被纯 Dart 单测覆盖。
library;

/// 无法转换成合法 ASCII 主机名时抛出。
///
/// 单独定义类型是为了让上层能精确 `catch`（UI 提示「测速地址含不支持的字符」），
/// 而不是把 `FormatException` / `ArgumentError` 混在一起处理。
class UnsupportedIdnException implements Exception {
  const UnsupportedIdnException(this.message, {this.codePoint});

  /// 人读原因，会直接展示给用户。
  final String message;

  /// 触发异常的码点（可空，例如「label 过长」就没有单一码点）。
  final int? codePoint;

  @override
  String toString() => codePoint == null
      ? 'UnsupportedIdnException: $message'
      : 'UnsupportedIdnException: $message（U+'
          '${codePoint!.toRadixString(16).toUpperCase().padLeft(4, '0')}）';
}

/// 允许出现在非 ASCII label 里的码点区段（IDNA2008 常见字母/数字区段子集）。
///
/// 用白名单而不是黑名单：黑名单永远漏（Emoji 有十几个区段、还有符号、变体选择符），
/// 而域名实际只会用到有限几种文字。命中不了的字符一律抛异常（K1 要求
/// 「不支持的字符显式抛，不静默降级」）。
const List<(int, int)> _kAllowedRanges = <(int, int)>[
  (0x00C0, 0x00FF), // Latin-1 补充（À-ÿ）；× ÷ 单独剔除
  (0x0100, 0x024F), // Latin Extended-A / -B
  (0x0370, 0x03FF), // 希腊
  (0x0400, 0x04FF), // 西里尔（默认测速地址用这个）
  (0x0530, 0x058F), // 亚美尼亚
  (0x0590, 0x05FF), // 希伯来
  (0x0600, 0x06FF), // 阿拉伯
  (0x0900, 0x097F), // 天城文
  (0x0E00, 0x0E7F), // 泰文
  (0x3040, 0x309F), // 平假名
  (0x30A0, 0x30FF), // 片假名
  (0x3400, 0x4DBF), // CJK 扩展 A
  (0x4E00, 0x9FFF), // CJK 基本区
  (0xAC00, 0xD7A3), // 谚文音节
  (0xF900, 0xFAFF), // CJK 兼容表意
];

/// 该码点是否在允许的字母/数字区段内。
bool _isAllowedUnicode(int codePoint) {
  // ×(U+00D7) ÷(U+00F7) 落在 Latin-1 补充里，但它们是运算符，不是字母
  if (codePoint == 0x00D7 || codePoint == 0x00F7) return false;
  for (final (lo, hi) in _kAllowedRanges) {
    if (codePoint >= lo && codePoint <= hi) return true;
  }
  return false;
}

/// 把主机名（可含多个 label）转成全 ASCII 形式。
///
/// 规则（对齐 IDNA2008 的常用子集）：
/// - 已经是 ASCII 的 label **原样返回，不改变大小写**（K1：全 ASCII 原样返回）；
/// - 非 ASCII label 先做最小 nameprep（小写折叠），再 punycode 编码并加 `xn--` 前缀；
/// - 解析不了（Emoji、组合附加符、超长 label、空 label）抛 [UnsupportedIdnException]；
/// - 结尾的点（`example.com.` 这种 FQDN 写法）保留。
String idnaToAscii(String host) {
  final raw = host.trim();
  if (raw.isEmpty) {
    throw const UnsupportedIdnException('域名为空');
  }
  final hasTrailingDot = raw.endsWith('.');
  final body = hasTrailingDot ? raw.substring(0, raw.length - 1) : raw;
  if (body.isEmpty) {
    throw UnsupportedIdnException('域名只有结尾的点：$host');
  }

  final labels = body.split('.');
  final out = <String>[];
  for (final label in labels) {
    if (label.isEmpty) {
      throw UnsupportedIdnException('域名里有空 label：$host');
    }
    out.add(_labelToAscii(label));
  }
  return hasTrailingDot ? '${out.join('.')}.' : out.join('.');
}

/// 单个 label 的 ASCII 化。
String _labelToAscii(String label) {
  if (_isAscii(label)) {
    return label; // 原样返回：大小写不丢（K1）
  }

  // 非 ASCII：小写折叠（punycode 只编码小写形式才与浏览器/系统一致）
  final folded = label.toLowerCase();
  for (final rune in folded.runes) {
    if (rune < 0x80) {
      final isAsciiAllowed = (rune >= 0x61 && rune <= 0x7A) || // a-z
          (rune >= 0x30 && rune <= 0x39) || // 0-9
          rune == 0x2D; // '-'
      if (!isAsciiAllowed) {
        throw UnsupportedIdnException(
          '不支持的字符: ${String.fromCharCode(rune)}',
          codePoint: rune,
        );
      }
      continue;
    }
    if (!_isAllowedUnicode(rune)) {
      throw UnsupportedIdnException(
        '不支持的字符: ${String.fromCharCode(rune)}',
        codePoint: rune,
      );
    }
  }

  final ascii = 'xn--${_punycodeEncode(folded)}';
  if (ascii.length > 63) {
    throw UnsupportedIdnException('单个 label 超过 63 字节：$ascii');
  }
  return ascii;
}

bool _isAscii(String s) {
  for (final rune in s.runes) {
    if (rune >= 0x80) return false;
  }
  return true;
}

/// 把地址字符串解析成「host 一定全 ASCII」的 [Uri]。
///
/// 这是**唯一允许**产出探测目标的入口：`LinkProbe` 内部只通过它拿 URI，
/// 日志与异常也只打印它给出的 host，保证用户看到的永远是 ASCII 主机名（K1 ③）。
///
/// 失败语义：
/// - 不是 http/https：抛 [FormatException]（文案以「测速地址必须以 http」开头，
///   与 Kotlin `LinkTestController` 的提示一致）；
/// - 主机名含不支持的字符：抛 [UnsupportedIdnException]，**不返回任何 URI**。
Uri probeUri(String speedUrl) {
  final trimmed = speedUrl.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('测速地址不能为空');
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
    throw FormatException('测速地址无法解析：$trimmed');
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    throw FormatException('测速地址必须以 http 开头：$trimmed');
  }
  // 注意：`Uri.host` 对非 ASCII 主机名返回的是 **百分号编码**形式
  // （`е.eu.org` → `%D0%B5.eu.org`），并不是原始 Unicode。直接拿它做
  // `_isAscii` 判断会得到「已是 ASCII」的错误结论，所以必须先解码回 Unicode。
  final rawHost = uri.host;
  final unicodeHost = _decodeHost(rawHost);
  if (_isAscii(unicodeHost)) {
    return uri;
  }
  return uri.replace(host: idnaToAscii(unicodeHost));
}

/// 把 `Uri.host` 里的百分号编码还原成 Unicode；解不出来就按原样返回。
String _decodeHost(String host) {
  if (!host.contains('%')) return host;
  try {
    return Uri.decodeComponent(host);
  } on Object {
    return host;
  }
}

// ---------------------------------------------------------------------------
// RFC 3492 punycode 编码器（只做编码，够用且可单测）
// ---------------------------------------------------------------------------

const int _kBase = 36;
const int _kTMin = 1;
const int _kTMax = 26;
const int _kSkew = 38;
const int _kDamp = 700;
const int _kInitialBias = 72;
const int _kInitialN = 128;
const int _kMaxInt = 0x7FFFFFFF;

/// 数字 → punycode 字符（0-25 → a-z，26-35 → 0-9）。
int _encodeDigit(int d) => d < 26 ? 0x61 + d : 0x30 + (d - 26);

/// bias 自适应（RFC 3492 §6.1）。
int _adapt(int delta, int numPoints, bool firstTime) {
  var d = firstTime ? delta ~/ _kDamp : delta ~/ 2;
  d += d ~/ numPoints;
  var k = 0;
  while (d > ((_kBase - _kTMin) * _kTMax) ~/ 2) {
    d ~/= _kBase - _kTMin;
    k += _kBase;
  }
  return k + ((_kBase - _kTMin + 1) * d) ~/ (d + _kSkew);
}

/// 输入必须已小写折叠，且至少含一个非 ASCII 码点（纯 ASCII 不走这里）。
String _punycodeEncode(String input) {
  final codePoints = input.runes.toList();
  final out = StringBuffer();

  // 1) 基本码点（< 0x80）原样输出，顺序不变
  for (final cp in codePoints) {
    if (cp < 0x80) out.writeCharCode(cp);
  }
  final basicCount = out.length;
  var handled = basicCount;
  if (basicCount > 0) out.write('-');

  var n = _kInitialN;
  var delta = 0;
  var bias = _kInitialBias;

  while (handled < codePoints.length) {
    // 2) 找下一个要编码的最小码点
    var m = _kMaxInt;
    for (final cp in codePoints) {
      if (cp >= n && cp < m) m = cp;
    }
    if (m - n > (_kMaxInt - delta) ~/ (handled + 1)) {
      throw const UnsupportedIdnException('label 太长，punycode 溢出');
    }
    delta += (m - n) * (handled + 1);
    n = m;

    for (final cp in codePoints) {
      if (cp < n) {
        delta++;
        if (delta > _kMaxInt) {
          throw const UnsupportedIdnException('label 太长，punycode 溢出');
        }
      }
      if (cp == n) {
        var q = delta;
        for (var k = _kBase;; k += _kBase) {
          final t =
              k <= bias ? _kTMin : (k >= bias + _kTMax ? _kTMax : k - bias);
          if (q < t) break;
          out.writeCharCode(_encodeDigit(t + (q - t) % (_kBase - t)));
          q = (q - t) ~/ (_kBase - t);
        }
        out.writeCharCode(_encodeDigit(q));
        bias = _adapt(delta, handled + 1, handled == basicCount);
        delta = 0;
        handled++;
      }
    }
    delta++;
    n++;
  }
  return out.toString();
}
