import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/app/desktop_theme.dart';
import 'package:pili_aurora/common/assets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('根主题更新 Windows 窗口图标，不依赖主页或托盘', (tester) async {
    const channel = MethodChannel('window_manager');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return call.method == 'isMinimized' ? false : null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final brightness = ValueNotifier(Brightness.light);
    addTearDown(brightness.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder(
        valueListenable: brightness,
        builder: (context, value, child) => MaterialApp(
          theme: ThemeData(brightness: value),
          home: const DesktopWindowTheme(child: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final value in [Brightness.light, Brightness.dark, Brightness.light]) {
      brightness.value = value;
      await tester.pumpAndSettle();
      final icon = calls.lastWhere((call) => call.method == 'setIcon');
      final path = (icon.arguments as Map)['iconPath'] as String;
      expect(
        path.replaceAll('\\', '/'),
        endsWith(Assets.themed(Assets.logoIco, value)),
      );
    }
    final count = calls.length;
    await tester.pump();
    expect(calls.length, count);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);

  testWidgets('隐藏窗口关闭视觉 ticker，失焦可见窗口继续更新', (tester) async {
    const channel = MethodChannel('window_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'isMinimized' ? false : null,
    );
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });
    bool? enabled;
    await tester.pumpWidget(MaterialApp(
      home: DesktopWindowTheme(child: Builder(builder: (context) {
        enabled = TickerMode.valuesOf(context).enabled;
        return const SizedBox();
      })),
    ));
    for (final state in [
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
      expect(enabled, state != AppLifecycleState.hidden);
    }
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);

  for (final restoredEvent in ['restore', 'maximize']) {
    testWidgets('最小化后通过 $restoredEvent 恢复，返回动画完成并释放页面', (tester) async {
      const channel = MethodChannel('window_manager');
      final messenger = tester.binding.defaultBinaryMessenger
        ..setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'isMinimized' ? false : null,
        );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        messenger.setMockMethodCallHandler(channel, null);
      });
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final navigator = GlobalKey<NavigatorState>();
      var disposed = false;
      bool? tickerEnabled;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (_, child) => DesktopWindowTheme(child: child!),
          home: const Scaffold(body: Text('直播列表')),
        ),
      );
      await tester.pump();
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => _ExitProbe(
              onDispose: () => disposed = true,
              child: Builder(
                builder: (context) {
                  tickerEnabled = TickerMode.valuesOf(context).enabled;
                  return Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('返回直播列表'),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _windowEvent(tester, 'maximize');
      await _windowEvent(tester, 'minimize');
      expect(tickerEnabled, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      await _windowEvent(tester, restoredEvent);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      await tester.tap(find.text('返回直播列表'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(disposed, isTrue, reason: '恢复后返回动画必须结束，页面才能释放播放器');
      expect(find.text('直播列表'), findsOneWidget);
      expect(tickerEnabled, isTrue);
      expect(tester.takeException(), isNull);
    }, skip: !Platform.isWindows);
  }
}

Future<void> _windowEvent(WidgetTester tester, String event) async {
  const channel = MethodChannel('window_manager');
  final completed = Completer<void>();
  tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    channel.name,
    channel.codec.encodeMethodCall(MethodCall('onEvent', {'eventName': event})),
    (_) => completed.complete(),
  );
  await completed.future;
  await tester.pump();
}

class _ExitProbe extends StatefulWidget {
  const _ExitProbe({required this.onDispose, required this.child});

  final VoidCallback onDispose;
  final Widget child;

  @override
  State<_ExitProbe> createState() => _ExitProbeState();
}

class _ExitProbeState extends State<_ExitProbe> {
  @override
  Widget build(BuildContext context) => widget.child;

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }
}
