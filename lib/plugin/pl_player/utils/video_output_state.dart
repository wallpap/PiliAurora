import 'package:pili_aurora/plugin/pl_player/utils/video_output_size.dart';

enum VideoOutputState { defaultPlayer, fullscreen, smallWindow }

/// Windows 窗口状态决定输出；布局只为待处理状态提供尺寸，不产生新请求。
class VideoOutputStateMachine {
  VideoOutputState? _state;
  bool _resizePending = true;

  VideoOutputState? get state => _state;
  bool get resizePending => _resizePending;

  VideoOutputState? transition({
    required bool isFullScreen,
    required bool isPipMode,
    bool isMaximized = false,
  }) {
    final next = isPipMode
        ? VideoOutputState.smallWindow
        : isFullScreen
        ? VideoOutputState.fullscreen
        : !isMaximized
        ? VideoOutputState.smallWindow
        : VideoOutputState.defaultPlayer;
    if (_state == next) return null;
    _state = next;
    _resizePending = true;
    return next;
  }

  void sourceChanged() => _resizePending = true;

  void acknowledgeResize() => _resizePending = false;

  VideoOutputSize? targetSize({
    required VideoOutputSize? source,
    required double logicalWidth,
    required double logicalHeight,
    required double devicePixelRatio,
  }) {
    if (!_resizePending ||
        _state == null ||
        source == null ||
        source.width <= 0 ||
        source.height <= 0) {
      return null;
    }
    // Windows 小窗可任意缩放，恢复源尺寸后只让 Flutter 缩放画面。
    if (_state == VideoOutputState.smallWindow) return source;
    return calculateVideoOutputSize(
      logicalWidth: logicalWidth,
      logicalHeight: logicalHeight,
      devicePixelRatio: devicePixelRatio,
      sourceWidth: source.width,
      sourceHeight: source.height,
    );
  }
}
