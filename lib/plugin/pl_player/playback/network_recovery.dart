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
    this.videoProgressing,
    this.canRecover,
    this.delay = const Duration(seconds: 3),
    this.cooldown = const Duration(seconds: 10),
  });

  final bool Function() isCurrent;
  final RecoveryState? Function() readState;
  final Future<void>? Function(bool tryNextCdn) reload;
  final void Function(Object error) onError;
  final void Function()? onRetry;
  final bool Function()? videoProgressing;
  final bool Function()? canRecover;
  final Duration delay;
  final Duration cooldown;
  final _clock = Stopwatch()..start();
  final _attempted = <(int, bool), Duration>{};
  Timer? _timer;
  bool _requireEmptyBuffer = true;
  bool _allowNativeRecovery = true;
  bool _waitForCachedPlayback = false;
  bool _tryNextCdn = false;
  bool _videoFailurePending = false;
  bool _networkFailurePending = false;
  RecoveryState? _failureState;
  RecoveryState? _previousState;
  (int, bool)? _scheduledAttempt;
  bool _inFlight = false;
  bool _permissionDenied = false;
  int _stalledChecks = 0;
  bool _disposed = false;
  bool get isActive => !_disposed && isCurrent();

  /// 强制恢复可关闭进度判断；读取失败可先保留剩余缓存。
  void schedule({
    bool requireEmptyBuffer = false,
    bool allowNativeRecovery = true,
    bool waitForCachedPlayback = false,
    bool tryNextCdn = false,
    int candidate = 0,
    bool throttle = false,
    bool requireVideoProgress = false,
  }) {
    if (_disposed || _permissionDenied || _inFlight || !isCurrent()) return;
    if (_timer != null) {
      _tryNextCdn |= tryNextCdn;
      if (requireVideoProgress) {
        _videoFailurePending = true;
        return;
      }
      if (_networkFailurePending) {
        _requireEmptyBuffer &= requireEmptyBuffer;
        _allowNativeRecovery &= allowNativeRecovery;
        _waitForCachedPlayback |= waitForCachedPlayback;
      } else {
        _networkFailurePending = true;
        _requireEmptyBuffer = requireEmptyBuffer;
        _allowNativeRecovery = allowNativeRecovery;
        _waitForCachedPlayback = waitForCachedPlayback;
        _failureState = _previousState = readState();
        _stalledChecks = 0;
      }
      if (!requireEmptyBuffer) _failureState = readState();
      return;
    }
    if (throttle) {
      final key = (candidate, requireEmptyBuffer);
      final last = _attempted[key];
      if (last != null && _clock.elapsed - last < cooldown) return;
      _attempted[key] = _clock.elapsed;
    }
    _requireEmptyBuffer = requireEmptyBuffer;
    _allowNativeRecovery = allowNativeRecovery;
    _waitForCachedPlayback = waitForCachedPlayback;
    _tryNextCdn = tryNextCdn;
    _videoFailurePending = requireVideoProgress;
    _networkFailurePending = !requireVideoProgress;
    _scheduledAttempt = throttle ? (candidate, requireEmptyBuffer) : null;
    _failureState = _previousState = readState();
    _stalledChecks = 0;
    _timer = Timer(delay, _check);
  }

  void _check() {
    _timer = null;
    if (_disposed || _permissionDenied || !isCurrent()) return;
    final videoStalled = videoProgressing?.call() == false;
    if (!_networkFailurePending && !videoStalled) {
      if (_scheduledAttempt case final key?) _attempted.remove(key);
      return;
    }
    final state = readState();
    if (state == null) return;
    if (canRecover?.call() == false) {
      _timer = Timer(delay, _check);
      return;
    }
    // 合并触发来源时分别确认故障，短暂停帧恢复后继续沿用网络侧的缓存判断。
    if (_videoFailurePending && videoStalled) {
      unawaited(_reload());
      return;
    }
    final lastCheck = _previousState;
    _previousState = state;
    final stalled =
        state.buffering &&
        lastCheck != null &&
        state.position <= lastCheck.position &&
        state.buffer <= lastCheck.buffer;
    _stalledChecks = stalled ? _stalledChecks + 1 : 0;
    final previous = _failureState;
    if (_allowNativeRecovery && previous != null) {
      // 新读入的数据需补足已消耗的时长，残余损坏包的少量推进仍要等待缓存耗尽。
      if (!state.buffering &&
          state.buffer > state.position &&
          state.position > previous.position &&
          state.buffer > previous.buffer &&
          state.buffer - state.position >=
              previous.buffer - previous.position) {
        // 本次没有重载，不占用下一次真实断流的限频名额。
        if (_scheduledAttempt case final key?) _attempted.remove(key);
        return;
      }
    }
    if (_waitForCachedPlayback && !videoStalled) {
      // 已确认画面停滞时，另一轨的缓存不应挡住恢复。
      // 缓冲状态下两次检查均无进展时，超前的缓存时间也可能无法继续播放。
      if (state.buffer > state.position && !stalled) {
        _timer = Timer(delay, _check);
        return;
      }
    } else if (_requireEmptyBuffer) {
      if (_stalledChecks < 2 &&
          !hasExhaustedPlaybackBuffer(
            buffering: state.buffering,
            position: state.position,
            buffer: state.buffer,
          )) {
        if (state.buffering || state.buffer > state.position) {
          _timer = Timer(delay, _check);
        }
        return;
      }
    }
    unawaited(_reload());
  }

  Future<void> _reload() async {
    _inFlight = true;
    try {
      final attempt = reload(_tryNextCdn);
      if (attempt == null) {
        _timer = Timer(delay, _check);
        return;
      }
      if (_requireEmptyBuffer) onRetry?.call();
      await attempt;
    } catch (error) {
      if (!_disposed) onError(error);
    } finally {
      _inFlight = false;
    }
  }

  void stopForPermissionFailure() {
    _permissionDenied = true;
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _clock.stop();
  }
}
