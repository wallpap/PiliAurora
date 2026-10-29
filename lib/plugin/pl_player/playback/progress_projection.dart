import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';

/// 加载交接期间保留展示位置，滤除原生卸载与 open 发出的临时零值。
class PlaybackProgressProjection {
  Duration? _initialPosition;

  bool get awaitingPosition => _initialPosition != null;

  void begin(Duration position) => _initialPosition = position;

  bool accept(PlaybackPhase phase, Duration position) {
    if (phase != PlaybackPhase.ready && phase != PlaybackPhase.ended) {
      return false;
    }
    if (_initialPosition != null &&
        _initialPosition! > Duration.zero &&
        (position - _initialPosition!).abs() > const Duration(seconds: 2)) {
      return false;
    }
    _initialPosition = null;
    return true;
  }
}
