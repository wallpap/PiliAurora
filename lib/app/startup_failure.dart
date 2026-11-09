import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/app/back_navigation.dart';
import 'package:pili_aurora/app/startup.dart';
import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/services/windows_update_exit.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:window_manager/window_manager.dart';

/// 不读取设置或账号；存储尚未就绪时也能显示错误并明确结束失败的进程。
Future<void> showStartupFailure(StartupFailure failure) async {
  WidgetsFlutterBinding.ensureInitialized();
  FocusManager.instance.removeEarlyKeyEventHandler(handleAppKeyEvent);
  runApp(StartupFailureApp(failure: failure, onClose: () => exit(1)));
  await WidgetsBinding.instance.endOfFrame;
  if (PlatformUtils.isDesktop) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(540, 400),
        minimumSize: Size(320, 280),
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.normal,
        title: Constants.appName,
      ),
    );
    // waitUntilReadyToShow 的 callback 为 void，不会等待其中的异步工作。
    await windowManager.show();
    await windowManager.focus();
  }
}

class StartupFailureApp extends StatefulWidget {
  const StartupFailureApp({
    super.key,
    required this.failure,
    required this.onClose,
  });

  final StartupFailure failure;
  final VoidCallback onClose;

  @override
  State<StartupFailureApp> createState() => _StartupFailureAppState();
}

class _StartupFailureAppState extends State<StartupFailureApp>
    with WindowListener {
  bool _copying = false;
  String? _copyMessage;

  @override
  void initState() {
    super.initState();
    if (PlatformUtils.isDesktop) windowManager.addListener(this);
    if (Platform.isWindows) {
      WindowsUpdateExit.setHandler(() async => widget.onClose());
    }
  }

  @override
  void dispose() {
    if (PlatformUtils.isDesktop) windowManager.removeListener(this);
    if (Platform.isWindows) WindowsUpdateExit.setHandler(null);
    super.dispose();
  }

  @override
  void onWindowClose() => widget.onClose();

  Future<void> _copySummary() async {
    if (_copying) return;
    setState(() => _copying = true);
    String message;
    try {
      await Clipboard.setData(
        ClipboardData(text: widget.failure.diagnosticSummary),
      );
      message = '已复制错误摘要';
    } catch (error, stackTrace) {
      logger.w('复制启动错误摘要失败', error: error.runtimeType, stackTrace: stackTrace);
      message = '复制失败，请重试';
    }
    if (!mounted) return;
    setState(() {
      _copying = false;
      _copyMessage = message;
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: Constants.appName,
    debugShowCheckedModeBanner: false,
    home: PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onClose();
      },
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 16,
                  children: [
                    const Text('应用启动失败', style: TextStyle(fontSize: 24)),
                    Text(widget.failure.message),
                    Text('失败阶段：${widget.failure.phase.label}'),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        FilledButton(
                          onPressed: widget.onClose,
                          child: const Text('关闭应用'),
                        ),
                        OutlinedButton(
                          onPressed: _copying ? null : _copySummary,
                          child: const Text('复制错误摘要'),
                        ),
                      ],
                    ),
                    if (_copyMessage != null)
                      Semantics(liveRegion: true, child: Text(_copyMessage!)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
