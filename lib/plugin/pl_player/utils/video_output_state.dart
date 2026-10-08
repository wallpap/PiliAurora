import 'package:pili_aurora/plugin/pl_player/utils/video_output_size.dart';

enum VideoOutputPlatform { android, windows }

enum VideoOutputState { defaultPlayer, fullscreen, smallWindow }

/// 平台事件决定状态；布局只为待处理的状态提供尺寸，不产生新请求。
class VideoOutputStateMachine {
  VideoOutputStateMachine(this.platform);

  final VideoOutputPlatform platform;
  VideoOutputState? _state;
  bool? _isLandscape;
  bool _resizePending = true;

  VideoOutputState? get state => _state;
  bool get resizePending => _resizePending;

  VideoOutputState? transition({
    required bool isFullScreen,
    required bool isPipMode,
    bool isMaximized = false,
    bool isLandscape = false,
  }) {
    final next = isPipMode
        ? VideoOutputState.smallWindow
        : isFullScreen
        ? VideoOutputState.fullscreen
        : platform == VideoOutputPlatform.windows && !isMaximized
        ? VideoOutputState.smallWindow
        : VideoOutputState.defaultPlayer;
    // Android 旋转可能不改变全屏标记，但仍需重新配置对应视口。
    final rotated =
        platform == VideoOutputPlatform.android &&
        next != VideoOutputState.smallWindow &&
        _isLandscape != isLandscape;
    _isLandscape = isLandscape;
    if (_state == next && !rotated) return null;
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
    if (platform == VideoOutputPlatform.android && isPortraitVideo(source)) {
      return null;
    }
    // Windows 小窗可任意缩放，恢复源尺寸后只让 Flutter 缩放画面。
    if (platform == VideoOutputPlatform.windows &&
        _state == VideoOutputState.smallWindow) {
      return source;
    }
    return calculateVideoOutputSize(
      logicalWidth: logicalWidth,
      logicalHeight: logicalHeight,
      devicePixelRatio: devicePixelRatio,
      sourceWidth: source.width,
      sourceHeight: source.height,
      preserveSourceAspectRatio: platform == VideoOutputPlatform.android,
    );
  }
}
