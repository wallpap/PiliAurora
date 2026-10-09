import 'package:flutter/widgets.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_size.dart';

/// 用启动时 Flutter 窗口所在显示器的物理像素限制 Windows 视频输出。
abstract final class WindowsVideoOutputLimit {
  static VideoOutputSize? _cached;

  static VideoOutputSize? get detected => _cached ??= _detect();

  static VideoOutputSize? _detect() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return null;
    final view = views.first;
    final size = view.display.size;
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 1 ||
        size.height <= 1) {
      return null;
    }
    return (width: size.width.round(), height: size.height.round());
  }
}
