/// 播放器加载任务的串行化与过期失效控制。
///
/// 约束：
/// - 同一时刻只允许一个任务的 operation 处于执行态，其余任务按调用顺序排队；
/// - 每次 [run] 同步分配递增代次，只有最新代次的任务才有意义（latest wins）；
/// - 排队中尚未开始的旧任务直接跳过；正在执行的任务通过 `isCurrent()` 在 await 之后
///   自行判断是否已被更新请求取代；
/// - 单个任务抛出的异常只传递给其自身的 Future，串行链继续可用；
/// - [dispose] 让所有代次失效并禁止新任务执行。
class PlaybackLoadQueue {
  /// 递增的代次标识。任务仅在自身代次等于当前代次时有效。
  int _generation = 0;

  /// 串行执行链的尾部，新任务始终挂到链尾，保证互斥执行。
  Future<void> _tail = Future<void>.value();

  bool _isLoading = false;
  bool _disposed = false;

  /// 是否处于加载状态。
  bool get isLoading => _isLoading;

  /// 排队并执行一次加载任务。
  ///
  /// 传入的 `isCurrent()` 用于在 await 之后判断自身是否已被更新请求覆盖；
  /// 返回 false 时应放弃后续副作用（例如界面赋值、回调派发）。
  Future<void> run(
    Future<void> Function(bool Function() isCurrent) operation,
  ) {
    if (_disposed) {
      // dispose 之后禁止新任务执行，直接完成以免调用方悬挂。
      return Future<void>.value();
    }

    // 同步分配代次并置位加载态，保证 run 返回时 isLoading 已为 true。
    final int generation = ++_generation;
    _isLoading = true;

    // 首任务也排队，确保 operation 同步重入 run 时链尾已更新，不会挂到旧链上并发。
    final Future<void> result = _tail.then(
      (_) => _execute(generation, operation),
    );

    // 链尾吞掉异常，保证失败任务不会毒化后续任务。
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  /// 执行单个任务，负责失效判断与加载态收尾。
  Future<void> _execute(
    int generation,
    Future<void> Function(bool Function() isCurrent) operation,
  ) async {
    // 排队期间已被更新请求取代，直接跳过（latest wins）。
    if (_disposed || generation != _generation) return;
    try {
      await operation(() => !_disposed && generation == _generation);
    } finally {
      // 旧任务的收尾不得清掉更新任务的加载态。
      if (generation == _generation) {
        _isLoading = false;
      }
    }
  }

  /// 使所有代次失效并阻止新任务执行。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _isLoading = false;
  }
}
