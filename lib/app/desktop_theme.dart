import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:window_manager/window_manager.dart';

/// 根节点同步窗口外观，主窗口和独立播放窗口共用。
class DesktopWindowTheme extends StatefulWidget {
  const DesktopWindowTheme({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopWindowTheme> createState() => _DesktopWindowThemeState();
}

class _DesktopWindowThemeState extends State<DesktopWindowTheme>
    with WidgetsBindingObserver, WindowListener {
  Brightness? _brightness;
  bool _minimized = false;
  int _windowEvent = 0;
  AppLifecycleState? _lifecycle;

  @override
  void initState() {
    super.initState();
    if (!Platform.isWindows) return;
    _lifecycle = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    final event = _windowEvent;
    unawaited(windowManager.isMinimized().then((value) {
      if (mounted && event == _windowEvent) {
        setState(() => _minimized = value);
      }
    }).catchError((Object error, StackTrace stack) {
      logger.w('读取窗口最小化状态失败', error: error, stackTrace: stack);
    }));
  }

  @override
  void onWindowMinimize() {
    _windowEvent++;
    if (mounted) setState(() => _minimized = true);
  }

  @override
  void onWindowRestore() {
    _windowEvent++;
    if (mounted) setState(() => _minimized = false);
  }

  // 从最小化恢复到最大化时，插件发送 maximize，也需要恢复视觉更新。
  @override
  void onWindowMaximize() => onWindowRestore();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    setState(() => _lifecycle = state);
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
    final brightness = Theme.of(context).brightness;
    if (_brightness == brightness) return;
    _brightness = brightness;
    unawaited(windowManager.setBrightness(brightness));
    if (Platform.isWindows) {
      unawaited(
        windowManager.setIcon(Assets.themed(Assets.logoIco, brightness)),
      );
    }
  }

  @override
  Widget build(BuildContext context) => TickerMode(
    // inactive 只表示失焦，其他播放窗口仍可能可见，不能停止其视觉更新。
    enabled: !Platform.isWindows ||
        (!_minimized &&
            _lifecycle != AppLifecycleState.hidden &&
            _lifecycle != AppLifecycleState.paused &&
            _lifecycle != AppLifecycleState.detached),
    child: widget.child,
  );

  @override
  void dispose() {
    if (Platform.isWindows) {
      windowManager.removeListener(this);
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }
}
