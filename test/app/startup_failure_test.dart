import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/app/startup.dart';
import 'package:pili_aurora/app/startup_failure.dart';

final _failure = StartupFailure(
  phase: StartupPhase.storage,
  cause: StateError('private credentials'),
  stackTrace: StackTrace.fromString('#0 storage.load'),
);

void main() {
  testWidgets('未初始化存储也能显示可读失败；只有点击时才写入剪贴板', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    var closed = 0;
    await tester.pumpWidget(
      StartupFailureApp(failure: _failure, onClose: () => closed++),
    );
    expect(find.text('应用启动失败'), findsOneWidget);
    expect(find.textContaining('无法读取本地配置或账号'), findsOneWidget);
    expect(find.textContaining('private'), findsNothing);
    expect(copied, isEmpty);
    await tester.tap(find.text('复制错误摘要'));
    await tester.pump();
    expect(copied.single, _failure.diagnosticSummary);
    expect(find.text('已复制错误摘要'), findsOneWidget);
    await tester.tap(find.text('关闭应用'));
    expect(closed, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('复制失败留在错误页，允许再次复制', (tester) async {
    var attempts = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData' && attempts++ == 0) {
          throw PlatformException(code: 'clipboard_unavailable');
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.pumpWidget(
      StartupFailureApp(failure: _failure, onClose: () {}),
    );
    await tester.tap(find.text('复制错误摘要'));
    await tester.pump();
    expect(find.text('复制失败，请重试'), findsOneWidget);
    // 诊断变更通知有 250ms 合并窗口。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('复制错误摘要'));
    await tester.pump();
    expect(attempts, 2);
    expect(find.text('已复制错误摘要'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('系统返回与桌面关闭事件使用同一个失败退出入口，卸载后释放监听', (tester) async {
    var closed = 0;
    await tester.pumpWidget(
      StartupFailureApp(failure: _failure, onClose: () => closed++),
    );
    final popScope = tester.widget<PopScope<void>>(find.byType(PopScope<void>));
    popScope.onPopInvokedWithResult!(false, null);
    expect(closed, 1);
    if (Platform.isWindows) {
      await _windowEvent(tester, 'close');
      expect(closed, 2);
    }
    await tester.pumpWidget(const SizedBox());
    if (Platform.isWindows) {
      await _windowEvent(tester, 'close');
      expect(closed, 2);
    }
  });

  testWidgets('错误窗口显示和聚焦完成后才交付，不读取设置或依赖普通窗口初始化', (tester) async {
    const channel = MethodChannel('window_manager');
    final calls = <MethodCall>[];
    final showing = Completer<Object?>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return switch (call.method) {
        'isMinimized' || 'isMaximized' || 'isFullScreen' => false,
        'show' => showing.future,
        _ => null,
      };
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    var completed = false;
    final presented = showStartupFailure(_failure)
      ..then((_) => completed = true);
    await tester.pump();
    await tester.pump();
    expect(calls.map((c) => c.method), contains('show'));
    expect(completed, isFalse);
    expect(calls.map((c) => c.method), isNot(contains('focus')));
    expect(
      calls.singleWhere((c) => c.method == 'setPreventClose').arguments,
      {'isPreventClose': true},
    );
    showing.complete(null);
    await tester.pump();
    await presented;
    expect(calls.last.method, 'focus');
    expect(completed, isTrue);
    expect(find.text('应用启动失败'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, skip: !Platform.isWindows);
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
