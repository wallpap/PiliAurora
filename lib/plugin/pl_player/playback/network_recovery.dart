import 'dart:async';

import 'package:pili_aurora/plugin/pl_player/utils/playback_network_recovery.dart';

typedef RecoveryState = ({
  bool buffering,
  Duration position,
  Duration buffer,
});

/// 一份媒体一轮恢复状态。计时器、限频和错误升级在这里收敛。
class PlaybackNetworkRecovery {
  PlaybackNetworkRecovery({
    required this.isCurrent,
    required this.readState,
    required this.reload,
    required this.onError,
    this.onRetry,
    this.delay = const Duration(seconds: 3),
    this.cooldown = const Duration(seconds: 10),
  });

  final bool Function() isCurrent;
  final RecoveryState? Function() readState;
  final Future<void>? Function(bool tryNextCdn) reload;
  final void Function(Object error) onError;
  final void Function()? onRetry;
  final Duration delay;
  final Duration cooldown;
  final _clock = Stopwatch()..start();
  final _attempted = <(int, bool), Duration>{};
  Timer? _timer;
  bool _requireEmptyBuffer = true;
  bool _tryNextCdn = false;
  bool _disposed = false;
  bool get isActive => !_disposed && isCurrent();

  void schedule({
    bool requireEmptyBuffer = false,
    bool tryNextCdn = false,
    int candidate = 0,
    bool throttle = false,
  }) {
    if (_disposed || !isCurrent()) return;
    if (_timer != null) {
      _requireEmptyBuffer &= requireEmptyBuffer;
      _tryNextCdn |= tryNextCdn;
      return;
    }
    if (throttle) {
      final key = (candidate, requireEmptyBuffer);
      final last = _attempted[key];
      if (last != null && _clock.elapsed - last < cooldown) return;
      _attempted[key] = _clock.elapsed;
    }
    _requireEmptyBuffer = requireEmptyBuffer;
    _tryNextCdn = tryNextCdn;
    _timer = Timer(delay, _check);
  }

  void _check() {
    _timer = null;
    if (_disposed || !isCurrent()) return;
    if (_requireEmptyBuffer) {
      final state = readState();
      if (state == null) return;
      if (!hasExhaustedPlaybackBuffer(
        buffering: state.buffering,
        position: state.position,
        buffer: state.buffer,
      )) {
        if (shouldDeferPlaybackNetworkRecovery(
          buffering: state.buffering,
          position: state.position,
          buffer: state.buffer,
        )) {
          _timer = Timer(delay, _check);
        }
        return;
      }
    }
    final attempt = reload(_tryNextCdn);
    if (attempt == null) {
      _timer = Timer(delay, _check);
      return;
    }
    if (_requireEmptyBuffer) onRetry?.call();
    attempt.catchError(onError);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _clock.stop();
  }
}
