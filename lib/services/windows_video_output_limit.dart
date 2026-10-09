import 'package:flutter/widgets.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 用启动时 Flutter 窗口所在显示器的物理像素限制 Windows 视频输出。
abstract final class WindowsVideoOutputLimit {
  static VideoOutputSize? _cached;

  static VideoOutputSize? get detected => _cached ??= _detect();

  static VideoOutputSize? _detect() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return null;
    final view = views.first;
    return VideoOutputSizePolicy.physicalDisplaySize(view.display.size);
  }
}
