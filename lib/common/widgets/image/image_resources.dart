import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

enum ImageWorkPriority { visible, prefetch }

class ImageResources {
  ImageResources({
    this.maximumConcurrentDecodes = 2,
    this.maximumRegionBytes = 64 << 20,
  }) : assert(maximumConcurrentDecodes > 0),
       assert(maximumRegionBytes > 0);

  static final _bindings = Expando<ImageResources>();
  static final _zoneKey = Object();
  static ImageResources get shared =>
      Zone.current[_zoneKey] as ImageResources? ??
      (_bindings[WidgetsBinding.instance] ??= ImageResources());

  static R runWith<R>(ImageResources resources, R Function() action) =>
      runZoned(action, zoneValues: {_zoneKey: resources});

  final int maximumConcurrentDecodes;
  final int maximumRegionBytes;
  final _memoryChanges = _ImageMemoryChanges();
  int _regionBytes = 0;
  int get regionBytes => _regionBytes;

  ImageMemoryReservation? reserveRegionBytes(int bytes) {
    if (bytes <= 0) throw ArgumentError.value(bytes, 'bytes');
    if (_disposed || bytes > maximumRegionBytes - _regionBytes) return null;
    _regionBytes += bytes;
    Diagnostics.instance.gauge('imageRegionBytes', _regionBytes);
    return ImageMemoryReservation._(this, bytes);
  }

  void addMemoryListener(VoidCallback listener) =>
      _memoryChanges.addListener(listener);
  void removeMemoryListener(VoidCallback listener) =>
      _memoryChanges.removeListener(listener);

  void _releaseRegionBytes(int bytes) {
    _regionBytes -= bytes;
    Diagnostics.instance.gauge('imageRegionBytes', _regionBytes);
    _memoryChanges.changed();
  }

  final _pending = <_ImageWorkBase>[];
  final _running = <_ImageWorkBase>{};
  final _drained = Completer<void>();
  Object? _lastOwner;
  bool _disposed = false;
  int _turn = 0;

  Future<void> get drained => _drained.future;

  ImageWork<T> schedule<T>(
    Future<T> Function() create, {
    required void Function(T) dispose,
    Object? owner,
    ImageWorkPriority priority = ImageWorkPriority.visible,
    bool preprocessing = false,
  }) {
    final work = ImageWork<T>._(
      this,
      create,
      dispose,
      owner,
      priority,
      preprocessing,
      _turn,
    );
    if (_disposed) {
      work.cancel();
    } else if (_pending.length >= 1024) {
      work._reject(StateError('图片解码队列已满'), StackTrace.current);
    } else {
      _pending.add(work);
      _drain();
    }
    return work;
  }

  ImageDecodePermit admit({Object? owner}) => ImageDecodePermit._(this, owner);

  void _drain() {
    if (_disposed) return;
    while (_running.length < maximumConcurrentDecodes) {
      final available = _pending.where(
        (work) =>
            !work.preprocessing ||
            !_running.any((entry) => entry.preprocessing),
      );
      if (available.isEmpty) break;
      int rank(_ImageWorkBase work) =>
          _turn - work.enqueuedAt >= 32 ? 0 : work.priority.index;
      var chosen = available.first;
      for (final work in available.skip(1)) {
        if (rank(work) < rank(chosen) ||
            (rank(work) == rank(chosen) &&
                chosen.owner == _lastOwner &&
                work.owner != _lastOwner)) {
          chosen = work;
        }
      }
      _pending.remove(chosen);
      _running.add(chosen);
      _lastOwner = chosen.owner;
      _turn++;
      chosen
        .._started = true
        ..start();
    }
    _report();
  }

  void _finished(_ImageWorkBase work) {
    _pending.remove(work);
    _running.remove(work);
    if (_disposed && _running.isEmpty && !_drained.isCompleted) {
      _drained.complete();
    }
    _drain();
    _report();
  }

  void _report() {
    Diagnostics.instance.gauge('imageDecodeActive', _running.length);
    Diagnostics.instance.gauge('imageDecodeQueued', _pending.length);
    Diagnostics.instance.gauge(
      'imageDecodeCancelledActive',
      _running.where((work) => work._cancelled).length,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final work in [..._pending, ..._running]) {
      work.cancel();
    }
    if (_running.isEmpty && !_drained.isCompleted) _drained.complete();
    _report();
  }
}

class ImageMemoryReservation {
  ImageMemoryReservation._(this._resources, this._bytes);
  final ImageResources _resources;
  int _bytes;
  int get bytes => _bytes;

  void shrinkTo(int bytes) {
    if (bytes < 0 || bytes > _bytes) throw ArgumentError.value(bytes, 'bytes');
    final released = _bytes - bytes;
    _bytes = bytes;
    if (released > 0) _resources._releaseRegionBytes(released);
  }

  void dispose() => shrinkTo(0);
}

class _ImageMemoryChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}

abstract class _ImageWorkBase {
  _ImageWorkBase(
    this.resources,
    this.owner,
    this.priority,
    this.preprocessing,
    this.enqueuedAt,
  );

  final ImageResources resources;
  final Object? owner;
  final ImageWorkPriority priority;
  final bool preprocessing;
  final int enqueuedAt;
  bool _started = false;
  bool _cancelled = false;
  void start();
  void cancel();
}

class ImageWork<T> extends _ImageWorkBase {
  ImageWork._(
    ImageResources resources,
    this._create,
    this._dispose,
    Object? owner,
    ImageWorkPriority priority,
    bool preprocessing,
    int turn,
  ) : super(resources, owner, priority, preprocessing, turn);

  final Future<T> Function() _create;
  final void Function(T) _dispose;
  final _result = Completer<T?>();
  final _drained = Completer<void>();

  Future<T?> get result => _result.future;
  Future<void> get drained => _drained.future;

  @override
  void start() => unawaited(_run());

  Future<void> _run() async {
    try {
      final value = await _create();
      if (_cancelled) {
        _dispose(value);
        _result.complete(null);
      } else {
        _result.complete(value);
      }
    } catch (error, stack) {
      if (_cancelled) {
        _result.complete(null);
      } else {
        _result.completeError(error, stack);
      }
    } finally {
      _drained.complete();
      resources._finished(this);
    }
  }

  void _reject(Object error, StackTrace stack) {
    _result.completeError(error, stack);
    _drained.complete();
  }

  @override
  void cancel() {
    if (_cancelled || _result.isCompleted) return;
    _cancelled = true;
    if (!_started) {
      _result.complete(null);
      _drained.complete();
      resources._finished(this);
    } else {
      resources._report();
    }
  }
}

class ImageDecodePermit {
  ImageDecodePermit._(ImageResources resources, Object? owner) {
    _work = resources.schedule<void>(
      () {
        _started = true;
        if (!_ready.isCompleted) _ready.complete();
        return _released.future;
      },
      dispose: (_) {},
      owner: owner,
    );
    unawaited(
      _work.result.then<void>(
        (_) {
          if (!_ready.isCompleted) _ready.complete();
        },
        onError: (Object error, StackTrace stack) {
          if (!_ready.isCompleted) _ready.completeError(error, stack);
        },
      ),
    );
  }

  late final ImageWork<void> _work;
  final _ready = Completer<void>();
  final _released = Completer<void>();
  bool _started = false;

  Future<void> get ready => _ready.future;
  bool get cancelled => _work._cancelled;

  void cancel() {
    if (_started) return;
    _work.cancel();
    if (!_ready.isCompleted) _ready.complete();
  }

  void release() {
    if (!_released.isCompleted) _released.complete();
    if (!_started) cancel();
  }
}
