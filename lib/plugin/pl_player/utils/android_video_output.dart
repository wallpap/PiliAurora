import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 应用层如需请求 Surface 尺寸，沿用插件管理的原生串行提交队列。
Future<bool> setAndroidVideoOutputSize({
  required NativePlayer player,
  required VideoOutputSize size,
  bool Function()? isCurrent,
  bool Function()? canStart,
  bool waitForFrame = false,
}) => setAndroidSurfaceSize(
  player: player,
  width: size.width,
  height: size.height,
  isCurrent: isCurrent,
  canStart: canStart,
  waitForFrame: waitForFrame,
);
