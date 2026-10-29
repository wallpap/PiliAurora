import 'dart:async';

import 'package:pili_aurora/plugin/pl_player/utils/playback_network_recovery.dart';

typedef AudioRecoveryState = ({
  bool playing,
  bool waiting,
  bool completed,
  Duration position,
  Duration duration,
  double? audioPts,
  double audioDelay,
});

enum AudioRecoveryStatus { idle, recovering, failed }

/// 出错后观察音频时钟；依次尝试外部音轨重连和一次整段重载。
class PlaybackAudioRecovery {
  PlaybackAudioRecovery({
    required this.readState,
    required this.repairAudio,
    required this.reload,
    required this.onError,
    this.onDiagnostic,
    this.onExhausted,
    this.onStatusChanged,
    this.elapsedMilliseconds,
  });

  final AudioRecoveryState? Function() readState;
  // null 表示加载繁忙；false 表示当前来源不支持独立音轨重连。
  final Future<bool>? Function() repairAudio;
  final Future<void>? Function() reload;
  final void Function(Object error) onError;
  final void Function(String action)? onDiagnostic;
  final void Function()? onExhausted;
  final void Function(AudioRecoveryStatus status)? onStatusChanged;
  final int Function()? elapsedMilliseconds;
  final _clock = Stopwatch()..start();
  Timer? _timer;
  AudioRecoveryState? _previous;
  int? _previousAtMs;
  int _generation = 0;
  int? _verificationRemainingMs;
  int? _healthySinceMs;
  bool _watching = false;
  bool _inFlight = false;
  bool _playbackChanged = false;
  bool _audioAttempted = false;
  bool _reloadAttempted = false;
  bool _notified = false;
  bool _decoderFailed = false;
  bool _streamReadFailed = false;
  int _streamReadFailureRevision = 0;
  bool _permissionDenied = false;
  bool _disposed = false;
  AudioRecoveryStatus _status = AudioRecoveryStatus.idle;
  int get _nowMs => elapsedMilliseconds?.call() ?? _clock.elapsedMilliseconds;
  bool get isActive => !_disposed && readState() != null;

  /// 原生健康信号也可启动观察，覆盖断流后没有新错误日志的情况。
  void observe() {
    if (_disposed) return;
    if (_permissionDenied) {
      final state = readState();
      if (state != null && _canObserve(state)) {
        _setStatus(AudioRecoveryStatus.failed);
      }
      return;
    }
    _watching = true;
    _schedule();
  }

  void _setStatus(AudioRecoveryStatus status) {
    if (_status == status) return;
    _status = status;
    onStatusChanged?.call(status);
  }

  void onLog({
    required String prefix,
    required String level,
    required String message,
  }) {
    if (_disposed || (level != 'error' && level != 'fatal')) return;
    if (isPlaybackPermissionFailure(message)) {
      reset();
      _permissionDenied = true;
      return;
    }
    if (_permissionDenied) return;
    final audioError =
        prefix == 'ffmpeg/audio' ||
        (prefix == 'ad' && message == 'Error decoding audio.');
    final readFailure = isPlaybackStreamReadFailure(
      prefix: prefix,
      level: level,
      message: message,
    );
    if (!audioError && !readFailure) {
      return;
    }
    if (readState() == null) return;
    if (readFailure) {
      _streamReadFailed = true;
      _streamReadFailureRevision++;
    }
    if (prefix == 'ad' && message == 'Error decoding audio.') {
      _decoderFailed = true;
    }
    if (!_watching) {
      _previous = null;
      _healthySinceMs = null;
    }
    _watching = true;
    _schedule();
  }

  /// 暂停、缓冲、拖动和静音期间让出恢复；恢复播放后继续确认遗留故障。
  void onPlaybackChanged() {
    if (_disposed || !_watching) return;
    if (_inFlight) {
      _playbackChanged = true;
      return;
    }
    _timer?.cancel();
    _timer = null;
    _previous = null;
    _previousAtMs = null;
    _healthySinceMs = null;
    _schedule();
  }

  bool _canObserve(AudioRecoveryState state) =>
      state.playing &&
      !state.waiting &&
      !state.completed &&
      (state.duration == Duration.zero ||
          state.position < state.duration - const Duration(seconds: 2));

  void _schedule() {
    if (_disposed || !_watching || _inFlight || _timer != null) return;
    final state = readState();
    if (state == null) {
      reset();
      return;
    }
    if (!_canObserve(state)) return;
    _previous ??= state;
    _previousAtMs ??= _nowMs;
    _timer = Timer(Duration(seconds: _notified ? 10 : 2), _check);
  }

  void _check() {
    _timer = null;
    final state = readState();
    if (_disposed || state == null) {
      reset();
      return;
    }
    if (!_canObserve(state)) {
      _previous = null;
      _previousAtMs = null;
      _healthySinceMs = null;
      return;
    }
    final previous = _previous;
    final observedMs = _previousAtMs == null ? 0 : _nowMs - _previousAtMs!;
    _previous = state;
    _previousAtMs = _nowMs;
    if (previous == null ||
        (state.position <= previous.position && !_decoderFailed)) {
      _healthySinceMs = null;
      _schedule();
      return;
    }
    if (_verificationRemainingMs case final remaining?) {
      _verificationRemainingMs = observedMs >= remaining
          ? 0
          : remaining - observedMs;
    }
    final pts = state.audioPts;
    final audioProgress =
        pts != null &&
        pts.isFinite &&
        (previous.audioPts == null || pts > previous.audioPts!);
    // 比较时间戳而非音量，静音片段仍会推进音频时钟。
    final inSync =
        pts != null &&
        pts.isFinite &&
        (state.position.inMicroseconds / 1000000 - state.audioDelay - pts)
                .abs() <
            1.5;
    if (audioProgress && inSync) {
      _decoderFailed = false;
      _setStatus(AudioRecoveryStatus.idle);
      if (_verificationRemainingMs == 0) {
        _verificationRemainingMs = null;
        onDiagnostic?.call('audio.recovery.verified');
      }
      _healthySinceMs ??= _nowMs;
      // 读取已经终止时，健康时钟仍可能来自残留缓存；等到重连后再确认恢复。
      if (!_streamReadFailed && _nowMs - _healthySinceMs! >= 30000) {
        reset();
        onDiagnostic?.call('audio.recovery.healthy');
        return;
      }
      _schedule();
      return;
    }
    _healthySinceMs = null;
    // 原生命令返回后继续等待音频时钟；暂停、缓冲和 seek 期间不计时。
    if ((_verificationRemainingMs ?? 0) > 0) {
      _schedule();
      return;
    }
    _verificationRemainingMs = null;
    if (_audioAttempted && _reloadAttempted) {
      _setStatus(AudioRecoveryStatus.failed);
      if (!_notified) {
        _notified = true;
        onDiagnostic?.call('audio.recovery.exhausted');
        onExhausted?.call();
      }
      _schedule();
      return;
    }
    _setStatus(AudioRecoveryStatus.recovering);
    unawaited(_recover());
  }

  Future<void> _recover() async {
    final generation = _generation;
    _inFlight = true;
    _playbackChanged = false;
    try {
      if (!_audioAttempted) {
        final readFailureRevision = _streamReadFailureRevision;
        final repair = repairAudio();
        if (repair == null) return;
        _audioAttempted = true;
        onDiagnostic?.call('audio.recovery.track.begin');
        final supported = await repair.timeout(const Duration(seconds: 8));
        if (_disposed || generation != _generation) return;
        if (supported) {
          if (readFailureRevision == _streamReadFailureRevision) {
            _streamReadFailed = false;
          }
          _verificationRemainingMs = 8000;
          onDiagnostic?.call('audio.recovery.track.accepted');
          return;
        }
        if (_playbackChanged) return;
      }
      final state = readState();
      if (state == null || !_canObserve(state)) return;
      final attempt = reload();
      if (attempt == null) return;
      _reloadAttempted = true;
      onDiagnostic?.call('audio.recovery.media.begin');
      await attempt;
      if (!_disposed && generation == _generation) {
        _verificationRemainingMs = 8000;
        onDiagnostic?.call('audio.recovery.media.accepted');
      }
    } catch (error) {
      if (!_disposed && generation == _generation) onError(error);
    } finally {
      if (!_disposed && generation == _generation) {
        _inFlight = false;
        _previous = null;
        _previousAtMs = null;
        _schedule();
      }
    }
  }

  void reset() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _previous = null;
    _previousAtMs = null;
    _verificationRemainingMs = null;
    _healthySinceMs = null;
    _watching = false;
    _inFlight = false;
    _playbackChanged = false;
    _audioAttempted = false;
    _reloadAttempted = false;
    _notified = false;
    _decoderFailed = false;
    _streamReadFailed = false;
    _permissionDenied = false;
    _setStatus(AudioRecoveryStatus.idle);
  }

  void dispose() {
    _disposed = true;
    reset();
    _clock.stop();
  }
}
