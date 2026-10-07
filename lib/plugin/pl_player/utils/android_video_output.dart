import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:pili_aurora/plugin/pl_player/utils/video_output_size.dart';

/// 控制 Android 原生输出尺寸的生命周期。
///
/// SurfaceTexture 的 buffer 尺寸属于媒体输出状态，不属于 Flutter 视口状态。
/// 一个媒体源建立输出后，旋转、全屏和布局变化只应由 Flutter 变换处理；
/// 只有源参数重建时才重新选择一次 buffer 尺寸。
class AndroidVideoOutputResizePolicy {
  bool _sourceResizePending = true;

  bool get sourceResizePending => _sourceResizePending;

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
