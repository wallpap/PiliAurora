import 'dart:math' as math;

import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';

enum SuperResolutionEligibility { allowed, unknownSize, resolutionTooHigh }

PlaybackConfiguration superResolutionConfigurationForPlan(
  PlaybackPlan plan, {
  required VideoOutputSize? display,
}) {
  final configuration = plan.configuration;
  final width = plan.metadata?.width;
  final height = plan.metadata?.height;
  if (configuration.shaders.isEmpty || width == null || height == null) {
    return configuration;
  }
  final eligibility = superResolutionEligibility(
    source: (width: width, height: height),
    display: display,
  );
  // 同内容切画质会继承会话配置，必须在首帧分配中间纹理前清除超分。
  return eligibility == SuperResolutionEligibility.resolutionTooHigh
      ? configuration.copyWith(shaders: const [])
      : configuration;
}

SuperResolutionEligibility superResolutionEligibility({
  required VideoOutputSize? source,
  required VideoOutputSize? display,
}) {
  if (source == null ||
      display == null ||
      source.width <= 0 ||
      source.height <= 0 ||
      display.width <= 0 ||
      display.height <= 0) {
    return .unknownSize;
  }
  // 用长短边比较物理像素，横竖屏旋转不改变设备可承载的分辨率。
  return math.max(source.width, source.height) >
              math.max(display.width, display.height) ||
          math.min(source.width, source.height) >
              math.min(display.width, display.height)
      ? .resolutionTooHigh
      : .allowed;
}
