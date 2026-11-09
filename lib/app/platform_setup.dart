import 'dart:io';

import 'package:pili_aurora/app/back_navigation.dart';
import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/plugin/pl_player/utils/fullscreen.dart';
import 'package:pili_aurora/services/service_locator.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/services/desktop_playback_windows.dart';
import 'package:pili_aurora/services/webview_environment.dart';
import 'package:pili_aurora/utils/calc_window_position.dart';
import 'package:pili_aurora/utils/max_screen_size.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/theme_utils.dart';
import 'package:pili_aurora/utils/desktop_window_background.dart';
import 'package:collection/collection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:window_manager/window_manager.dart' hide calcWindowPosition;

/// 初始化平台能力；Windows WebView 必须在 `Request.setCookie()` 前就绪。
Future<void> initializePlatformServices() async {
  if (PlatformUtils.isMobile) {
    if (Platform.isAndroid) MaxScreenSize.init();
    await Future.wait([
      if (Pref.horizontalScreen) ?fullMode() else ?portraitUpMode(),
      setupServiceLocator(),
    ]);
  } else if (Platform.isWindows) {
    await AppWebViewEnvironment.initialize(
      userDataPath: path.join(appSupportDirPath, 'flutter_inappwebview'),
    );
  }
}

/// 配置移动端系统 UI，或创建并显示桌面应用窗口。
Future<void> initializePlatformWindow() async {
  if (PlatformUtils.isMobile) {
    await SystemChrome.setEnabledSystemUIMode(.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        statusBarColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
      ),
    );
    if (Platform.isAndroid) {
      try {
        final mode = await FlutterDisplayMode.supported;
        final String? storageDisplay = GStorage.setting.get(
          SettingBoxKey.displayMode,
        );
        DisplayMode? displayMode;
        if (storageDisplay != null) {
          displayMode = mode.firstWhereOrNull(
            (e) => e.toString() == storageDisplay,
          );
        }
        await FlutterDisplayMode.setPreferredMode(
          displayMode ?? DisplayMode.auto,
        );
      } catch (error, stackTrace) {
        // 刷新率选择是可选能力，失败时保留系统模式并继续启动。
        logger.w('设置显示模式失败', error: error.runtimeType, stackTrace: stackTrace);
      }
    } else {
      await ScreenBrightnessPlatform.instance.setAutoReset(false);
    }
  } else if (PlatformUtils.isDesktop) {
    FocusManager.instance.addEarlyKeyEventHandler(handleAppKeyEvent);

    await windowManager.ensureInitialized();
    if (Platform.isWindows) {
      final (light, dark) = ThemeUtils.getAllTheme();
      final isDark =
          Pref.themeMode == ThemeMode.dark ||
          (Pref.themeMode == ThemeMode.system &&
              WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                  Brightness.dark);
      await DesktopWindowBackground.setThemeColor(
        DesktopPlaybackWindows.isPlayerWindow
            ? Colors.black
            : (isDark ? dark : light).scaffoldBackgroundColor,
      );
    }
    if (DesktopPlaybackWindows.isPlayerWindow) {
      final windows = DesktopPlaybackWindows.instance;
      await windowManager.waitUntilReadyToShow(
        const WindowOptions(
          minimumSize: Size(320, 180),
          titleBarStyle: TitleBarStyle.hidden,
          title: 'PiliAurora Player',
          backgroundColor: Color(0xFF000000),
        ),
      );
      await windowManager.setBounds(windows.initialBounds!);
      await windowManager.setAlwaysOnTop(true);
      return;
    }

    final windowOptions = WindowOptions(
      minimumSize: const Size(400, 720),
      skipTaskbar: false,
      titleBarStyle: Pref.showWindowTitleBar
          ? TitleBarStyle.normal
          : TitleBarStyle.hidden,
      title: Constants.appName,
    );
    await windowManager.waitUntilReadyToShow(windowOptions);
    final windowSize = Pref.windowSize;
    await windowManager.setBounds(
      await calcWindowPosition(windowSize) & windowSize,
    );
    if (Pref.isWindowMaximized) await windowManager.maximize();
    await windowManager.show();
    await windowManager.focus();
  }
}
