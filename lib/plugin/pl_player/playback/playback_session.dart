import 'package:pili_aurora/plugin/pl_player/utils/playback_load_queue.dart';

/// 页面借用同一套播放器资源；最近进入的页面拥有加载权。
class PlaybackSession {
  final _loads = PlaybackLoadQueue();
  final _owners = <PlaybackOwner>[];
  int _revision = 0;
  bool _disposed = false;

  bool get isLoading => _loads.isLoading;
  bool get isDisposed => _disposed;
  int get revision => _revision;
  Future<void> get drained => _loads.drained;

  PlaybackOwner attach() {
    final owner = PlaybackOwner._(this);
    if (_disposed) return owner.._closed = true;
    _owners.lastOrNull?.invalidateRequests();
    _owners.add(owner);
    _invalidate();
    return owner;
  }

  bool isCurrent(int revision) => !_disposed && revision == _revision;

  Future<void> load(
    PlaybackOwner owner,
    Future<void> Function(bool Function() isCurrent) operation, {
    bool Function()? isValid,
  }) {
    if (!identical(owner._session, this) ||
        !owner.isActive ||
        !(isValid?.call() ?? true)) {
      return Future.value();
    }
    final revision = ++_revision;
    return _loads.run((isCurrent) async {
      bool valid() =>
          isCurrent() &&
          owner.isActive &&
          this.isCurrent(revision) &&
          (isValid?.call() ?? true);
      if (valid()) await operation(valid);
    });
  }

  Future<void>? reload(
    Future<void> Function(bool Function() isCurrent) operation,
  ) {
    if (_disposed || isLoading || _owners.isEmpty) return null;
    final revision = _revision;
    return _loads.run((isCurrent) async {
      bool valid() => isCurrent() && this.isCurrent(revision);
      if (valid()) await operation(valid);
    });
  }

  void _release(PlaybackOwner owner) {
    final wasActive = owner.isActive;
    _owners.remove(owner);
    owner._closed = true;
    owner._requests.close();
    if (wasActive) _invalidate();
  }

  void _activate(PlaybackOwner owner) {
    if (owner._closed || _disposed || owner.isActive) return;
    _owners.lastOrNull?.invalidateRequests();
    _owners
      ..remove(owner)
      ..add(owner);
    _invalidate();
  }

  void _invalidate() {
    _revision++;
    _loads.invalidate();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final owner in _owners) {
      owner._closed = true;
      owner._requests.close();
    }
    _owners.clear();
    _revision++;
    _loads.dispose();
  }
}

class PlaybackOwner {
  PlaybackOwner._(this._session);
  final PlaybackSession _session;
  final _requests = _PlaybackRequests();
  int _generation = 0;
  bool _closed = false;

  bool get isActive =>
      !_closed &&
      !_session._disposed &&
      identical(_session._owners.lastOrNull, this);

  void close() {
    if (!_closed) _session._release(this);
  }

  void activate() => _session._activate(this);

  bool get isQuerying => _requests.isRunning;

  Future<void> query(
    Future<void> Function(bool Function() isCurrent) operation, {
    required bool Function() isValid,
    void Function()? cancel,
  }) => _requests.run(
    operation,
    isValid: () => isActive && isValid(),
    cancel: cancel,
  );

  void invalidateRequests() {
    _generation++;
    _requests.invalidate();
  }

  bool Function() guard() {
    final generation = _generation;
    return () => isActive && generation == _generation;
  }
}

/// 地址查询并发执行，结果提交遵循最近一次请求；关闭与切集同步失效。
class _PlaybackRequests {
  int _generation = 0;
  bool _running = false;
  bool _closed = false;
  void Function()? _cancel;

  bool get isRunning => _running;

  Future<void> run(
    Future<void> Function(bool Function() isCurrent) operation, {
    required bool Function() isValid,
    void Function()? cancel,
  }) async {
    if (_closed || !isValid()) return;
    final generation = ++_generation;
    _cancel?.call();
    _cancel = cancel;
    _running = true;
    bool isCurrent() => !_closed && generation == _generation && isValid();
    try {
      await operation(isCurrent);
    } finally {
      if (generation == _generation) {
        _running = false;
        _cancel = null;
      }
    }
  }

  void invalidate() {
    _generation++;
    _running = false;
    _cancel?.call();
    _cancel = null;
  }

  void close() {
    _closed = true;
    invalidate();
  }
}
