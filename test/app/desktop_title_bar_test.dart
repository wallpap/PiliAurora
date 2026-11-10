import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/app/desktop_title_bar.dart';
import 'package:pili_aurora/utils/desktop_window_background.dart';

void main() {
  testWidgets('标题栏提示完整绘制在页面内容之上', (tester) async {
    const channel = MethodChannel('window_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'isMaximized' ? false : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final boundaryKey = GlobalKey();
    const pageColor = Color(0xFFFF00FF);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          builder: (context, child) => DesktopWindowFrame(child: child!),
          home: const ColoredBox(color: pageColor),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byTooltip('最小化')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    final text = find.text('最小化', findRichText: true);
    expect(text, findsOneWidget);
    final rect = tester.getRect(text);
    expect(rect.bottom, greaterThan(36));
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final tooltipPixel = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final offset =
          (rect.center.dy.floor() * image.width + rect.center.dx.floor()) * 4;
      final pixel = data!.getUint32(offset);
      image.dispose();
      return pixel;
    });
    // 直接检查绘制结果，避免提示存在于树中却被页面覆盖时误报通过。
    expect(tooltipPixel, isNot(0xFF00FFFF));
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('自绘窗口按钮跟随主题，最大化事件更新还原入口，关闭沿用窗口事件', (tester) async {
    const channel = MethodChannel('window_manager');
    final calls = <String>[];
    final initialMaximized = Completer<bool>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      return call.method == 'isMaximized' ? initialMaximized.future : null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    for (final brightness in [
      Brightness.light,
      Brightness.dark,
      Brightness.light,
    ]) {
      final theme = ThemeData(brightness: brightness);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const DesktopWindowFrame(child: SizedBox()),
        ),
      );
      await tester.pumpAndSettle();
      final button = tester.widget<TextButton>(
        find.widgetWithIcon(TextButton, Icons.remove),
      );
      expect(
        button.style!.foregroundColor!.resolve({}),
        theme.colorScheme.onSurface,
      );
    }
    await tester.tap(find.byTooltip('最小化'));
    await tester.pump();
    expect(calls.last, 'minimize');
    await tester.tap(find.byTooltip('最大化'));
    await tester.pump();
    expect(calls.last, 'maximize');
    await _windowEvent(tester, 'maximize');
    await tester.pump();
    // 初始化查询迟到不能覆盖已收到的最大化状态。
    initialMaximized.complete(false);
    await tester.pump();
    expect(find.byTooltip('还原'), findsOneWidget);
    await tester.tap(find.byTooltip('还原'));
    await tester.pump();
    expect(calls.last, 'unmaximize');
    await _windowEvent(tester, 'unmaximize');
    await tester.pump();
    expect(find.byTooltip('最大化'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    expect(calls.last, 'close');
    await tester.pumpWidget(const SizedBox());
    await _windowEvent(tester, 'maximize');
    expect(tester.takeException(), isNull);
  });

  testWidgets('全屏隐藏标题栏并保留内容状态，退出恢复；设置可隐藏标题栏', (tester) async {
    const manager = MethodChannel('window_manager');
    final messenger = tester.binding.defaultBinaryMessenger
      ..setMockMethodCallHandler(
        manager,
        (call) async => call.method == 'isMaximized' ? false : null,
      )
      ..setMockMethodCallHandler(
        DesktopWindowBackground.channel,
        (_) async => null,
      );
    addTearDown(() async {
      await tester.runAsync(() => DesktopWindowBackground.setFullscreen(false));
      messenger
        ..setMockMethodCallHandler(manager, null)
        ..setMockMethodCallHandler(DesktopWindowBackground.channel, null);
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: DesktopWindowFrame(child: Material(child: TextField())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '保留页面');
    await tester.runAsync(() => DesktopWindowBackground.setFullscreen(true));
    await tester.pump();
    expect(find.byType(DesktopTitleBar), findsNothing);
    expect(find.text('保留页面'), findsOneWidget);
    await tester.runAsync(() => DesktopWindowBackground.setFullscreen(false));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopTitleBar), findsOneWidget);
    expect(find.text('保留页面'), findsOneWidget);
    await tester.pumpWidget(
      const MaterialApp(
        home: DesktopWindowFrame(showTitleBar: false, child: SizedBox()),
      ),
    );
    expect(find.byType(DesktopTitleBar), findsNothing);
  });
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
