import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_size.dart';
import 'package:pili_aurora/utils/android/android_helper.dart';

/// 自动检测设备物理分辨率，作为 Android 视频 Surface 输出上限。
abstract final class AndroidVideoOutputLimit {
  static VideoOutputSize? _cached;

  static VideoOutputSize? get detected => _cached ??= _detect();

  static VideoOutputSize? _detect() {
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    if (view == null) return null;

    final display = view.display;
    (int, int)? fallbackLogicalSize;
    if (!_isValidSize(display.size)) {
      try {
        fallbackLogicalSize = PiliAndroidHelper.maxScreenSize();
      } catch (_) {
        // 检测不可用时不限制源尺寸，避免影响播放。
      }
    }
    return resolve(
      displaySize: display.size,
      devicePixelRatio: display.devicePixelRatio,
      fallbackLogicalSize: fallbackLogicalSize,
    );
  }

  /// [displaySize] 为物理像素；原生备用值来自 Android 最大显示区域的逻辑像素。
  static VideoOutputSize? resolve({
    required ui.Size displaySize,
    required double devicePixelRatio,
    (int, int)? fallbackLogicalSize,
  }) {
    var size = displaySize;
    if (!_isValidSize(size)) {
      if (fallbackLogicalSize == null ||
          !devicePixelRatio.isFinite ||
          devicePixelRatio <= 0) {
        return null;
      }
      size = ui.Size(
        fallbackLogicalSize.$1 * devicePixelRatio,
        fallbackLogicalSize.$2 * devicePixelRatio,
      );
    }
    if (!_isValidSize(size)) return null;
    return (
      width: size.longestSide.round(),
      height: size.shortestSide.round(),
    );
  }

  static bool _isValidSize(ui.Size size) =>
      size.width.isFinite &&
      size.height.isFinite &&
      size.width > 1 &&
      size.height > 1;
}
