import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/desktop_window_visibility.dart';
import 'package:pili_aurora/utils/desktop_window_background.dart';
import 'package:window_manager/window_manager.dart';

/// 根节点同步窗口外观，主窗口和独立播放窗口共用。
class DesktopWindowTheme extends StatefulWidget {
  const DesktopWindowTheme({
    super.key,
    required this.child,
    this.backgroundColor,
  });

  final Widget child;
  final Color? backgroundColor;

  @override
  State<DesktopWindowTheme> createState() => _DesktopWindowThemeState();
}

class _DesktopWindowThemeState extends State<DesktopWindowTheme>
    with
        WidgetsBindingObserver,
        WindowListener,
        DesktopWindowVisibilityListener {
  Brightness? _brightness;
  Color? _backgroundColor;
  bool _windowVisible = true;
  int _windowEvent = 0;

  @override
  void initState() {
    super.initState();
    Assets.iconStyle.addListener(_syncIcon);
    if (!Platform.isWindows) return;
    didChangeAppLifecycleState(
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed,
    );
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    final event = _windowEvent;
    unawaited(
      windowManager
          .isMinimized()
          .then((value) {
            if (mounted && event == _windowEvent) {
              if (value) {
                onWindowMinimize();
              } else {
                onWindowRestore();
              }
            }
          })
          .catchError((Object error, StackTrace stack) {
            logger.w('读取窗口最小化状态失败', error: error, stackTrace: stack);
          }),
    );
  }

  @override
  void onWindowVisibilityChanged(bool visible) {
    _windowEvent++;
    if (mounted) setState(() => _windowVisible = visible);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      // SchedulerBinding 会在这些状态下禁止普通 frame；强制提交一次
      // TickerMode 更新，让子树及时释放视觉订阅和显示资源。
      SchedulerBinding.instance.scheduleForcedFrame();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncBackground();
    final brightness = Theme.of(context).brightness;
    if (_brightness == brightness) return;
    _brightness = brightness;
    unawaited(windowManager.setBrightness(brightness));
    _syncIcon();
  }

  @override
  void didUpdateWidget(DesktopWindowTheme oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncBackground();
  }

  void _syncBackground() {
    final color =
        widget.backgroundColor ?? Theme.of(context).scaffoldBackgroundColor;
    if (_backgroundColor == color) return;
    _backgroundColor = color;
    unawaited(DesktopWindowBackground.setThemeColor(color));
  }

  void _syncIcon() {
    if (Platform.isWindows && _brightness != null) {
      unawaited(
        windowManager.setIcon(Assets.themed(Assets.logoIco, _brightness!)),
      );
    }
  }

  @override
  Widget build(BuildContext context) => TickerMode(
    // inactive 只表示失焦，其他播放窗口仍可能可见，不能停止其视觉更新。
    enabled: !Platform.isWindows || _windowVisible,
    child: widget.child,
  );

  @override
  void dispose() {
    Assets.iconStyle.removeListener(_syncIcon);
    if (Platform.isWindows) {
      windowManager.removeListener(this);
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }
}
