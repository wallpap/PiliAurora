import 'dart:async';

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

  /// 保留串行执行链，使尚未结束的原生操作完成后再执行下一次加载。
  void invalidate() {
    _generation++;
    _isLoading = false;
  }

  Future<void> get drained => _tail;

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

enum PlaybackOperationSlot {
  load,
  recovery,
  decoder,
  audioOnly,
  audioTrack,
  subtitleTrack,
  output,
  shader,
  seek,
  playbackSpeed,
  volume,
  muted,
}

enum PlaybackOperationOutcome {
  completed,
  superseded,
  timedOut,
  closed,
  failed,
}

class PlaybackOperationResult<T> {
  const PlaybackOperationResult._(
    this.outcome, {
    this.value,
    this.error,
  });

  const PlaybackOperationResult.completed(T value)
    : this._(PlaybackOperationOutcome.completed, value: value);
  const PlaybackOperationResult.superseded()
    : this._(PlaybackOperationOutcome.superseded);
  const PlaybackOperationResult.timedOut()
    : this._(PlaybackOperationOutcome.timedOut);
  const PlaybackOperationResult.closed()
    : this._(PlaybackOperationOutcome.closed);
  const PlaybackOperationResult.failed(Object error)
    : this._(PlaybackOperationOutcome.failed, error: error);

  final PlaybackOperationOutcome outcome;
  final T? value;
  final Object? error;
}

class PlaybackOperationContext {
  const PlaybackOperationContext({
    required this.deadline,
    required this.isCurrent,
  });

  final Duration deadline;
  final bool Function() isCurrent;
}

/// Single executor with one replaceable pending slot per operation kind.
/// Expired/cancelled callers settle immediately; an active native operation
/// remains the executor until its cleanup returns.
class PlaybackOperationScheduler {
  PlaybackOperationScheduler({required this.now});

  final Duration Function() now;
  final Map<PlaybackOperationSlot, _ScheduledPlaybackOperation<dynamic>>
  _pending = {};
  _ScheduledPlaybackOperation<dynamic>? _active;
  Completer<void>? _drain;
  int _sequence = 0;
  bool _disposed = false;

  bool get isRunning => _active != null;
  bool get isDisposed => _disposed;
  Future<void> get drained => _drain?.future ?? Future<void>.value();

  Future<PlaybackOperationResult<T>> submit<T>({
    required PlaybackOperationSlot slot,
    required Duration deadline,
    required Future<T> Function(PlaybackOperationContext context) operation,
    void Function()? cancel,
  }) {
    if (_disposed) {
      return Future.value(PlaybackOperationResult<T>.closed());
    }
    if (deadline <= now()) {
      return Future.value(PlaybackOperationResult<T>.timedOut());
    }

    final previousPending = _pending.remove(slot);
    if (previousPending != null) {
      _cancelTask(previousPending, PlaybackOperationOutcome.superseded);
    }
    final active = _active;
    if (active?.slot == slot) {
      _cancelTask(active!, PlaybackOperationOutcome.superseded);
    }

    final task = _ScheduledPlaybackOperation<T>(
      slot: slot,
      sequence: _sequence++,
      deadline: deadline,
      operation: operation,
      cancel: cancel,
    );
    _pending[slot] = task;
    _drain ??= Completer<void>();
    final remaining = deadline - now();
    task.timer = Timer(remaining, () {
      _expire(task);
    });
    _pump();
    return task.result.future;
  }

  /// A new user load cancels queued configuration/recovery targets. The
  /// currently executing operation is cancelled cooperatively and drains.
  void prioritizeLoad() {
    _pending.removeWhere((slot, task) {
      if (slot == PlaybackOperationSlot.load) return false;
      _cancelTask(task, PlaybackOperationOutcome.superseded);
      return true;
    });
    final active = _active;
    if (active != null && active.slot != PlaybackOperationSlot.load) {
      _cancelTask(active, PlaybackOperationOutcome.superseded);
    }
    _pump();
    _finishDrainIfIdle();
  }

  void cancel(PlaybackOperationSlot slot) {
    final pending = _pending.remove(slot);
    if (pending != null) {
      _cancelTask(pending, PlaybackOperationOutcome.superseded);
    }
    final active = _active;
    if (active?.slot == slot) {
      _cancelTask(active!, PlaybackOperationOutcome.superseded);
    }
    _finishDrainIfIdle();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final task in _pending.values.toList()) {
      _cancelTask(task, PlaybackOperationOutcome.closed);
    }
    _pending.clear();
    final active = _active;
    if (active != null) _cancelTask(active, PlaybackOperationOutcome.closed);
    _finishDrainIfIdle();
  }

  void _expire(_ScheduledPlaybackOperation<dynamic> task) {
    if (task.settled) return;
    if (identical(_pending[task.slot], task)) _pending.remove(task.slot);
    _cancelTask(task, PlaybackOperationOutcome.timedOut);
    _pump();
    _finishDrainIfIdle();
  }

  void _cancelTask(
    _ScheduledPlaybackOperation<dynamic> task,
    PlaybackOperationOutcome outcome,
  ) {
    if (task.cancelled) return;
    task.cancelled = true;
    task.timer?.cancel();
    try {
      task.cancel?.call();
    } catch (_) {
      // Cancellation callbacks are hints; a callback failure cannot strand
      // the scheduler or change the operation's typed terminal result.
    }
    // Keep the operation's generic result type. The pending map is erased to
    // dynamic so the executor can arbitrate heterogeneous slots, but settling
    // through PlaybackOperationResult<dynamic> fails at runtime for T !=
    // dynamic.
    task.settleCancelled(outcome);
  }

  void _settle<T>(
    _ScheduledPlaybackOperation<T> task,
    PlaybackOperationResult<T> result,
  ) {
    if (task.settled) return;
    task.settled = true;
    task.timer?.cancel();
    task.result.complete(result);
  }

  void _pump() {
    if (_disposed || _active != null || _pending.isEmpty) {
      _finishDrainIfIdle();
      return;
    }
    final task = _pending.values.reduce((left, right) {
      final priority = left.slot.index.compareTo(right.slot.index);
      if (priority < 0) return left;
      if (priority > 0) return right;
      return left.sequence <= right.sequence ? left : right;
    });
    _pending.remove(task.slot);
    _active = task;
    if (task.cancelled || task.deadline <= now()) {
      if (!task.settled) _cancelTask(task, PlaybackOperationOutcome.timedOut);
      _active = null;
      _pump();
      return;
    }
    // Dispatch through the typed task instance so T survives the heterogeneous
    // slot map. Calling _execute(task) here infers dynamic from the map value,
    // which makes completing Completer<PlaybackOperationResult<T>> fail.
    task.start(this);
  }

  Future<void> _execute<T>(_ScheduledPlaybackOperation<T> task) async {
    try {
      if (!task.isCurrent(this)) {
        if (!task.settled && task.deadline <= now()) _expire(task);
        return;
      }
      final value = await task.operation(
        PlaybackOperationContext(
          deadline: task.deadline,
          isCurrent: () => task.isCurrent(this),
        ),
      );
      if (!task.settled) {
        if (task.deadline <= now()) {
          _expire(task);
        } else {
          _settle(task, PlaybackOperationResult<T>.completed(value));
        }
      }
    } catch (error) {
      if (!task.settled) {
        if (task.deadline <= now()) {
          _expire(task);
        } else {
          _settle(task, PlaybackOperationResult<T>.failed(error));
        }
      }
    } finally {
      if (identical(_active, task)) _active = null;
      _pump();
    }
  }

  void _finishDrainIfIdle() {
    if (_active != null || _pending.isNotEmpty) return;
    final drain = _drain;
    _drain = null;
    if (drain != null && !drain.isCompleted) drain.complete();
  }
}

class _ScheduledPlaybackOperation<T> {
  _ScheduledPlaybackOperation({
    required this.slot,
    required this.sequence,
    required this.deadline,
    required this.operation,
    this.cancel,
  });

  final PlaybackOperationSlot slot;
  final int sequence;
  final Duration deadline;
  final Future<T> Function(PlaybackOperationContext context) operation;
  final void Function()? cancel;
  final result = Completer<PlaybackOperationResult<T>>();
  Timer? timer;
  bool cancelled = false;
  bool settled = false;

  void start(PlaybackOperationScheduler scheduler) {
    unawaited(scheduler._execute<T>(this));
  }

  void settleCancelled(PlaybackOperationOutcome outcome) {
    if (settled) return;
    final PlaybackOperationResult<T> result = switch (outcome) {
      PlaybackOperationOutcome.superseded =>
        PlaybackOperationResult<T>.superseded(),
      PlaybackOperationOutcome.timedOut =>
        PlaybackOperationResult<T>.timedOut(),
      PlaybackOperationOutcome.closed => PlaybackOperationResult<T>.closed(),
      PlaybackOperationOutcome.completed => throw StateError(
        'Completed result needs an operation value.',
      ),
      PlaybackOperationOutcome.failed => throw StateError(
        'Failed result needs an error.',
      ),
    };
    settled = true;
    timer?.cancel();
    this.result.complete(result);
  }

  bool isCurrent(PlaybackOperationScheduler scheduler) =>
      !scheduler.isDisposed &&
      !cancelled &&
      deadline > scheduler.now() &&
      (identical(scheduler._active, this) ||
          identical(scheduler._pending[slot], this));
}
