import 'dart:async';

/// A borrowed mpv event remains valid until acknowledgement. Stop first drains
/// any callback already reading it, then joins the reader, then returns to the
/// handle owner. Never use a fixed timer as proof that the reader has exited.
class EventLoopSession<E> {
  EventLoopSession({
    required this.onEvent,
    required this.acknowledge,
    required this.shutdown,
    required this.onError,
  });

  final FutureOr<void> Function(E event) onEvent;
  final void Function() acknowledge;
  final FutureOr<void> Function() shutdown;
  final void Function(Object error, StackTrace stack) onError;
  Future<void> _pending = Future.value();
  Future<void>? _stop;
  bool _closing = false;
  bool _closed = false;

  bool get closing => _closing;

  void add(E event) {
    if (_closed) return;
    _pending = _pending.then((_) async {
      try {
        if (!_closing) await onEvent(event);
      } catch (error, stack) {
        onError(error, stack);
      } finally {
        if (!_closed) acknowledge();
      }
    });
  }

  Future<void> stop() {
    _closing = true;
    return _stop ??= _shutdown();
  }

  Future<void> _shutdown() async {
    await _pending;
    await shutdown();
    _closed = true;
  }
}
