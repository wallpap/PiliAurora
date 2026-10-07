import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:pili_aurora/plugin/pl_player/utils/video_output_size.dart';

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
