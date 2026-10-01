import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/models/hwdec_type.dart';

/// 统一构造传给原生播放器的硬解配置。
VideoControllerConfiguration hardwareVideoConfiguration({
  required bool enabled,
  required String configured,
}) {
  return VideoControllerConfiguration(
    enableHardwareAcceleration: enabled,
    androidAttachSurfaceAfterVideoParameters: false,
    // 由 mpv 顺序探测并处理运行时回退；不依赖特定等级或措辞的错误日志。
    hwdec: enabled ? HwDecType.orderedCandidates(configured).join(',') : 'no',
  );
}
