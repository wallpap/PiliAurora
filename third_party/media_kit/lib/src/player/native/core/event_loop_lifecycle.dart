import 'dart:async';

/// Records the backend which actually owns each handle. Disposal never probes
/// a different backend or races native destruction against asynchronous stop.
class EventLoopLifecycle<T> {
  EventLoopLifecycle({
    required this.handleId,
    required this.nativeDispose,
    required this.isolateDispose,
    required this.onNativeFailure,
  });

  final int Function(T handle) handleId;
  final FutureOr<void> Function(T handle) nativeDispose;
  final FutureOr<void> Function(T handle) isolateDispose;
  final void Function(Object error, StackTrace stack) onNativeFailure;
  final _owners = <int, FutureOr<void> Function(T)>{};
  final _stops = <int, Future<void>>{};

  Future<T> create({
    required FutureOr<T> Function() nativeCreate,
    required FutureOr<T> Function() isolateCreate,
  }) async {
    late T handle;
    late FutureOr<void> Function(T) stop;
    try {
      handle = await nativeCreate();
      stop = nativeDispose;
    } catch (error, stack) {
      onNativeFailure(error, stack);
      handle = await isolateCreate();
      stop = isolateDispose;
    }
    _owners[handleId(handle)] = stop;
    return handle;
  }

  Future<void> dispose(T handle) {
    final id = handleId(handle);
    final pending = _stops[id];
    if (pending != null) return pending;
    final stop = _owners.remove(id);
    if (stop == null) return Future.value();
    final future = Future<void>.sync(() => stop(handle));
    _stops[id] = future;
    return future.whenComplete(() {
      if (identical(_stops[id], future)) _stops.remove(id);
    });
  }
}
