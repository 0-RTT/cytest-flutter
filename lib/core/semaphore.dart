import 'dart:async';
import 'dart:collection';

/// 取消信号：[Semaphore.drain] 之后，所有等待中的 `acquire()` 与后续
/// `acquire()` 都会以本异常失败。
///
/// 之所以用异常而不是返回 bool：调用方（runner）在 `Future.wait` 里派发十几路
/// 探测，用返回值判定就得每处都写 `if (!ok) return;`，漏一处就变成「取消后仍然
/// 发请求」；异常会沿着 await 链自动冒泡，漏不掉。
class CancelledException implements Exception {
  const CancelledException([this.message = '已取消']);

  /// 人读原因（会进日志）。
  final String message;

  @override
  String toString() => 'CancelledException: $message';
}

/// 并发闸门：限制同时进行的异步任务数，支持整体取消。
///
/// 只有 30 行的最小实现，不引入 `pool` / `synchronized` 之类依赖（K1 精神：
/// 本次不新增第三方依赖）。
///
/// 语义与「分批 `Future.wait`」的关键区别：这里的等待者是 FIFO 队列，
/// 任何一路完成就立刻放行下一路。分批写法会等整批最慢的一条，
/// 慢链会把后续批次拖到超时，尾部延迟剧烈抖动。
///
/// 用法：
/// ```dart
/// final gate = Semaphore(6);
/// await Future.wait(ports.map((p) => gate.withPermit(() => probe(p))));
/// ```
class Semaphore {
  /// [permits] 必须为正：0 会让所有任务永久挂住。
  Semaphore(this._permits, {this.name = 'semaphore'})
      : assert(_permits > 0, '闸门许可数必须为正');

  final String name;

  int _permits;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  bool _drained = false;

  /// 当前可用许可数（不含已被等待者「预定」的）。
  int get permits => _permits;

  /// 当前排队等待的调用数。
  int get waiting => _waiters.length;

  /// 是否已被 [drain] 永久关闭。
  bool get drained => _drained;

  /// 取得一个许可。无许可时挂起，直到有人 [release]。
  ///
  /// 闸门已 [drain] 时立即以 [CancelledException] 失败。
  Future<void> acquire() {
    if (_drained) {
      return Future<void>.error(const CancelledException());
    }
    if (_permits > 0) {
      _permits--;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  /// 归还一个许可：优先直接交给排在最前面的等待者，避免「先 +1 再 -1」的抖动。
  ///
  /// 重复 [release] 会让许可数虚增，进而突破并发上限，所以调用方必须保证
  /// 「acquire 成功才 release」——[withPermit] 里用 `finally` 保证了这一点。
  void release() {
    if (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (!waiter.isCompleted) waiter.complete();
      return;
    }
    _permits++;
  }

  /// 取许可执行 [task]，无论成败都归还许可。
  Future<T> withPermit<T>(Future<T> Function() task) async {
    await acquire();
    try {
      return await task();
    } finally {
      release();
    }
  }

  /// 取消：唤醒所有等待者（以 [CancelledException] 失败），并让后续 acquire 立即失败。
  ///
  /// 幂等：重复调用无副作用。注意它**不会**打断已经在跑的任务——那由调用方
  /// 通过关闭 HttpClient / kill 进程完成（取消链路三段）。
  void drain() {
    if (_drained) return;
    _drained = true;
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (!waiter.isCompleted) {
        waiter.completeError(const CancelledException());
      }
    }
  }

  /// 重新打开闸门（一次测试会话结束、准备下一次运行时用）。
  ///
  /// 不重置 [permits]：在途任务是 0 个时它们本来就等于初始许可数，
  /// 硬重置反而会把「漏 release」的 bug 掩盖掉。
  void reopen() {
    _drained = false;
  }
}
