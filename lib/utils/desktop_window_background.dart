import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:window_manager/window_manager.dart';

/// 合成背景与 GDI 擦除共用同一颜色，串行提交主题和全屏状态变化。
abstract final class DesktopWindowBackground {
  static const channel = MethodChannel('piliaurora/window_background');
  static Color _themeColor = const Color(0xFF000000);
  static bool _fullscreen = false;
  static Future<void> _pending = Future.value();

  static Future<void> setThemeColor(Color color) {
    _themeColor = color;
    return _apply();
  }

  static Future<void> setFullscreen(bool fullscreen) {
    _fullscreen = fullscreen;
    return _apply();
  }

  static Future<void> _apply() {
    if (!Platform.isWindows) return Future.value();
    final color = _fullscreen ? const Color(0xFF000000) : _themeColor;
    return _pending = _pending
        .then((_) async {
          await channel.invokeMethod<void>(
            'setColor',
            color.toARGB32() & 0xFFFFFF,
          );
          await windowManager.setBackgroundColor(color);
        })
        .catchError((Object error, StackTrace stack) {
          logger.w('同步窗口背景失败', error: error, stackTrace: stack);
        });
  }
}
