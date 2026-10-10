import 'dart:io' show Platform, exit;

import 'package:pili_aurora/utils/android/bindings.g.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, Size;
import 'package:win32/win32.dart' as kernel32;

abstract final class DeviceUtils {
  static void exitApp() {
    if (Platform.isWindows) {
      // WebView2 的退出清理可能阻塞，沿用主窗口的原生退出方式。
      kernel32.TerminateProcess(kernel32.GetCurrentProcess(), 0);
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
