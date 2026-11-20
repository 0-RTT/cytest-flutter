import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// 经本机 SOCKS5（Xray 的 mixed 入站同时支持 SOCKS 与 HTTP）建立到目标的连接，
/// 再把这条 socket 当作 [SSHSocket] 交给 SSH 客户端。
///
/// 为什么需要它：SSH 是裸 TCP，没有 `findProxy` 这种东西；Xray 的入站只提供
/// SOCKS/HTTP 代理协议，所以必须自己做完 SOCKS5 握手再接管 socket。
///
/// 为什么不用 `HttpClient`：那只能发 HTTP 请求，给不了「一条干净的字节流」。
Future<SSHSocket> connectViaSocks5({
  required String proxyHost,
  required int proxyPort,
  required String host,
  required int port,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final raw = await Socket.connect(proxyHost, proxyPort, timeout: timeout);
  final sock = _SocksSocket(raw);
  try {
    await sock._handshake(host, port).timeout(timeout);
    return sock;
  } on Object {
    sock.destroy();
    rethrow;
  }
}

class _SocksSocket implements SSHSocket {
  _SocksSocket(this._raw) {
    _sub = _raw.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );
  }

  final Socket _raw;
  late final StreamSubscription<Uint8List> _sub;

  /// 握手阶段收到的字节先攒着（可能一次就读到多余的数据）。
  final List<int> _buf = <int>[];
  Completer<void>? _bufWait;

  /// 握手完成后，后续字节直接转给 SSH 层。
  final StreamController<Uint8List> _out = StreamController<Uint8List>();
  bool _handshakeDone = false;

  @override
  Stream<Uint8List> get stream => _out.stream;

  @override
  StreamSink<List<int>> get sink => _raw;

  @override
  Future<void> get done => _raw.done;

  @override
  Future<void> close() async {
    await _raw.close();
    if (!_out.isClosed) await _out.close();
  }

  @override
  void destroy() {
    _sub.cancel();
    _raw.destroy();
    if (!_out.isClosed) _out.close();
  }

  @override
  Future<void> flush() async {}

  // --- 握手 ---------------------------------------------------------------

  Future<void> _handshake(String host, int port) async {
    // 1) 问候：VER=5, NMETHODS=1, METHOD=0（无认证）。Xray 的入站不校验账号。
    _raw.add(<int>[0x05, 0x01, 0x00]);
    await _raw.flush();
    final greeting = await _read(2);
    if (greeting[0] != 0x05 || greeting[1] != 0x00) {
      throw const SocketException('SOCKS5 代理拒绝无认证方式');
    }

    // 2) CONNECT，ATYP=3（域名）交给代理解析：本地 DNS 常常解析不到或拿到脏结果。
    final hostBytes = Uint8List.fromList(host.codeUnits);
    if (hostBytes.length > 255) {
      throw const SocketException('主机名过长，无法用 SOCKS5 域名方式连接');
    }
    _raw.add(<int>[
      0x05, 0x01, 0x00, 0x03, hostBytes.length, //
      ...hostBytes,
      (port >> 8) & 0xff, port & 0xff,
    ]);
    await _raw.flush();

    // 3) 应答：VER REP RSV ATYP [BND.ADDR] BND.PORT
    final head = await _read(4);
    if (head[1] != 0x00) {
      throw SocketException('SOCKS5 连接失败（REP=${head[1]}）');
    }
    final atyp = head[3];
    if (atyp == 0x01) {
      await _read(4);
    } else if (atyp == 0x04) {
      await _read(16);
    } else if (atyp == 0x03) {
      final len = (await _read(1))[0];
      await _read(len);
    } else {
      throw SocketException('SOCKS5 应答里出现未知地址类型 $atyp');
    }
    await _read(2); // BND.PORT

    // 4) 交棒：缓冲区里剩下的字节（握手应答之后多读到的）先吐给 SSH 层。
    _handshakeDone = true;
    if (_buf.isNotEmpty) {
      _out.add(Uint8List.fromList(_buf));
      _buf.clear();
    }
  }

  Future<List<int>> _read(int n) async {
    while (_buf.length < n) {
      final waiter = Completer<void>();
      _bufWait = waiter;
      await waiter.future;
    }
    final out = _buf.sublist(0, n);
    _buf.removeRange(0, n);
    return out;
  }

  void _onData(Uint8List chunk) {
    if (_handshakeDone) {
      if (!_out.isClosed) _out.add(chunk);
      return;
    }
    _buf.addAll(chunk);
    final waiter = _bufWait;
    if (waiter != null && !waiter.isCompleted) {
      _bufWait = null;
      waiter.complete();
    }
  }

  void _onError(Object error, StackTrace st) {
    final waiter = _bufWait;
    if (waiter != null && !waiter.isCompleted) {
      _bufWait = null;
      waiter.completeError(error, st);
    }
    if (!_out.isClosed) _out.addError(error, st);
  }

  void _onDone() {
    if (!_out.isClosed) _out.close();
  }
}
