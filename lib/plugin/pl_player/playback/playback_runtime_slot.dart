import 'dart:async';

/// Serializes creation of the process's interactive native player resource.
///
/// A reservation remains held until the supplied native `released` future
/// completes. A failed or timed out caller cannot make an unconfirmed player
/// available to another controller.
class PlaybackRuntimeSlot {
  PlaybackRuntimeSlot._();

  /// 独立诊断播放器使用自己的资源队列，不占用日常播放的租约。
  PlaybackRuntimeSlot.isolated();

  static final shared = PlaybackRuntimeSlot._();

  Completer<void>? _reservation;
  Future<void>? _resourceReleased;
  Object? _releaseError;

  Future<PlaybackRuntimeSlotLease?> acquire({
    required Duration deadline,
    required Duration Function() now,
    Future<void>? cancelled,
    bool Function()? isCancelled,
  }) async {
    while (true) {
      final remaining = deadline - now();
      if (remaining <= Duration.zero) return null;
      if (isCancelled?.call() ?? false) return null;

      final releaseError = _releaseError;
      if (releaseError != null) return null;

      final released = _resourceReleased;
      if (released != null) {
        try {
          await _wait(released, remaining, cancelled);
        } on TimeoutException {
          return null;
        } on _SlotCancelled {
          return null;
        } catch (error) {
          _releaseError = error;
          return null;
        }
        if (identical(_resourceReleased, released)) {
          _resourceReleased = null;
          _releaseError = null;
        }
        continue;
      }

      final reservation = _reservation;
      if (reservation != null) {
        try {
          await _wait(reservation.future, remaining, cancelled);
        } on TimeoutException {
          return null;
        } on _SlotCancelled {
          return null;
        }
        continue;
      }

      final claimed = Completer<void>();
      _reservation = claimed;
      if (isCancelled?.call() ?? false) {
        _reservation = null;
        claimed.complete();
        return null;
      }
      return PlaybackRuntimeSlotLease._(this, claimed);
    }
  }

  Future<void> _wait(
    Future<void> waitFor,
    Duration remaining,
    Future<void>? cancelled,
  ) async {
    if (cancelled == null) {
      await waitFor.timeout(remaining);
      return;
    }
    await Future.any<void>([
      waitFor,
      cancelled.then<void>((_) => throw const _SlotCancelled()),
    ]).timeout(remaining);
  }

  void _retain(
    PlaybackRuntimeSlotLease lease,
    Completer<void> reservation,
    Future<void> released,
  ) {
    if (!identical(_reservation, reservation) || lease._finished) return;
    lease._attached = true;
    _resourceReleased = released;
    unawaited(
      released.then<void>(
        (_) {
          if (!identical(_resourceReleased, released)) return;
          _resourceReleased = null;
          _releaseError = null;
          _reservation = null;
          if (!reservation.isCompleted) reservation.complete();
          lease._finished = true;
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_resourceReleased, released)) {
            // Keep the reservation: an error is not evidence of release.
            _releaseError = error;
          }
        },
      ),
    );
  }

  void _release(
    PlaybackRuntimeSlotLease lease,
    Completer<void> reservation,
  ) {
    if (lease._finished || lease._attached) return;
    lease._finished = true;
    if (identical(_reservation, reservation)) {
      _reservation = null;
      if (!reservation.isCompleted) reservation.complete();
    }
  }
}

class PlaybackRuntimeSlotLease {
  PlaybackRuntimeSlotLease._(this._slot, this._reservation);

  final PlaybackRuntimeSlot _slot;
  final Completer<void> _reservation;
  bool _attached = false;
  bool _finished = false;

  /// Transfers the reservation to the native resource's actual release.
  void attachReleased(Future<void> released) {
    if (_finished || _attached) return;
    _slot._retain(this, _reservation, released);
  }

  /// Releases a reservation when initialization failed before obtaining a
  /// native resource. Once attached, only its `released` future can free it.
  void release() => _slot._release(this, _reservation);
}

class _SlotCancelled implements Exception {
  const _SlotCancelled();
}
