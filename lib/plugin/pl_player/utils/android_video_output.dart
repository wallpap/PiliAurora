import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'package:pili_aurora/plugin/pl_player/utils/video_output_size.dart';

const _channel = MethodChannel('com.alexmercerind/media_kit_video');

/// 调整 Android `SurfaceTexture` 的实际输出尺寸。
///
/// media_kit_video 在 Android 上不实现 `VideoController.setSize`，但其原生
/// 通道已经提供了设置 SurfaceTexture buffer size 的能力。这里复用该通道，
/// 并通知 mpv 重新创建 gpu 输出；当前视频输出已经拥有有效 `wid`，无需暴露
/// 第三方插件内部的 Surface 引用。
Future<bool> setAndroidVideoOutputSize({
  required NativePlayer player,
  required VideoOutputSize size,
  bool Function()? isCurrent,
}) async {
  if (player.disposed ||
      player.current.isEmpty ||
      !(isCurrent?.call() ?? true)) {
    return false;
  }
  final media = player.current.first;
  await _channel.invokeMethod<void>(
    'VideoOutputManager.SetSurfaceTextureSize',
    <String, String>{
      'handle': player.handle.toString(),
      'width': size.width.toString(),
      'height': size.height.toString(),
    },
  );

  // 通道等待期间可能切源或销毁，不能用旧尺寸重新激活新的/已释放的输出。
  if (player.disposed ||
      player.current.isEmpty ||
      !identical(player.current.first, media) ||
      !(isCurrent?.call() ?? true)) {
    return false;
  }
  player
    ..setOption('android-surface-size', '${size.width}x${size.height}')
    ..setOption('vo', 'gpu');
  return true;
}
