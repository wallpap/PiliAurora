import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:synchronized/synchronized.dart';

const _channel = MethodChannel('com.alexmercerind/media_kit_video');
// 插件的源尺寸重建与应用的视口适配必须共用提交队列；只串行应用请求不够。
// Expando 不持有已销毁播放器，也不需要独立维护全局 handle 清理列表。
final _locks = Expando<Lock>('Android video surface size');

/// 串行修改 Android buffer，并同步同一媒体的 mpv 输出尺寸。
///
/// [isCurrent] 只检查 Surface 生命周期，不检查最新视口或播放状态：
/// 平台调用已经改变 buffer 时，不能因新视口请求取消 mpv 同步。
/// [wid] 仅供插件首次挂载/重建 Surface 时更新原生窗口引用。
Future<bool> setAndroidSurfaceSize({
  required NativePlayer player,
  required int width,
  required int height,
  bool Function()? isCurrent,
  int? wid,
}) {
  if (player.disposed || player.current.isEmpty) return Future.value(false);
  // 入队前绑定媒体，排队期间切源不能把旧尺寸提交到新媒体。
  final media = player.current.first;
  bool current() =>
      !player.disposed &&
      player.current.isNotEmpty &&
      identical(player.current.first, media) &&
      (isCurrent?.call() ?? true);
  final lock = _locks[player] ??= Lock();
  return lock.synchronized(() async {
    if (!current()) return false;
    await _channel.invokeMethod<void>(
      'VideoOutputManager.SetSurfaceTextureSize',
      <String, String>{
        'handle': player.handle.toString(),
        'width': width.toString(),
        'height': height.toString(),
      },
    );
    if (!current()) return false;
    player.setOption('android-surface-size', '${width}x$height');
    if (wid != null) {
      // 只有挂载/重建源 Surface 才启动 VO。单纯视口调整由
      // android-surface-size 的 EXTERNAL_RESIZE 通知完成，不重新选择 VO。
      player.setOption('wid', wid.toString());
      player.setOption('vo', 'gpu');
    }
    return true;
  });
}
