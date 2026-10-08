import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:pili_aurora/plugin/pl_player/utils/video_output_size.dart';

/// Android 播放器的有限输出状态。
///
/// 不把每一帧布局变化当成新的原生输出请求：非竖屏视频只在这几个
/// 播放器状态之间切换时重新选择一次 SurfaceTexture buffer 尺寸。
enum AndroidVideoOutputState {
  devicePortrait,
  fullscreen,
  smallWindow,
}

/// 管理 Android 原生输出的状态转换和媒体源生命周期。
class AndroidVideoOutputStateMachine {
  AndroidVideoOutputState? _state;
  bool _sourceResizePending = true;

  AndroidVideoOutputState? get state => _state;
  bool get sourceResizePending => _sourceResizePending;

  /// 根据优先级计算状态：PiP 可能伴随全屏标记，必须优先视为小窗。
  AndroidVideoOutputState? transition({
    required bool isFullScreen,
    required bool isPipMode,
  }) {
    final nextState = isPipMode
        ? AndroidVideoOutputState.smallWindow
        : isFullScreen
        ? AndroidVideoOutputState.fullscreen
        : AndroidVideoOutputState.devicePortrait;
    if (_state == nextState) return null;
    _state = nextState;
    return nextState;
  }

  /// 标记新的媒体源或新的原生 Surface，需要重新配置一次输出 buffer。
  void sourceChanged() => _sourceResizePending = true;

  /// 消费本媒体源唯一一次的尺寸配置机会。
  bool takeSourceResize() {
    if (!_sourceResizePending) return false;
    _sourceResizePending = false;
    return true;
  }
}

/// 应用只提供视口尺寸，原生提交顺序由插件统一管理。
/// 源视频参数重建也走相同队列，不能在应用侧另建互不关联的原生通道。
Future<bool> setAndroidVideoOutputSize({
  required NativePlayer player,
  required VideoOutputSize size,
  bool Function()? isCurrent,
}) => setAndroidSurfaceSize(
  player: player,
  width: size.width,
  height: size.height,
  isCurrent: isCurrent,
);
