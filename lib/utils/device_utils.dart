import 'package:pili_aurora/services/app_exit.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/desktop_playback_windows.dart';

import 'dart:io' show OSError, Platform, exit;

import 'package:pili_aurora/utils/android/bindings.g.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, Size;
import 'package:win32/win32.dart' as kernel32;

abstract final class DeviceUtils {
  static final _exit = AppExit(
    cleanup: [
      if (Platform.isWindows)
        ('windows', DesktopPlaybackWindows.instance.closeAll),
    ],
    flushDiagnostics: Diagnostics.instance.flush,
    terminate: _terminate,
  );

  static Future<void> exitApp() => _exit.close();

  static void _terminate() {
    if (Platform.isWindows) {
      // WebView2 的退出清理可能阻塞，沿用主窗口的原生退出方式。
      final result = kernel32.TerminateProcess(kernel32.GetCurrentProcess(), 0);
      if (!result.value) throw OSError('结束应用进程失败', result.error);
    } else {
      exit(0);
    }
  }

  static final int sdkInt = AndroidHelper.sdkInt();

  static bool get isTablet {
    return size.shortestSide >= 600;
  }

  static Size get size {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return view.physicalSize / view.devicePixelRatio;
  }

  static String get platformName => PlatformUtils.isDesktop
      ? 'desktop'
      : isTablet
      ? 'pad'
      : 'phone';
}
