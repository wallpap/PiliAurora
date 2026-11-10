import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/app/back_navigation.dart';
import 'package:pili_aurora/app/platform_setup.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const window = MethodChannel('window_manager');
  const background = MethodChannel('piliaurora/window_background');
  const screen = MethodChannel('dev.leanflutter.plugins/screen_retriever');
  const display = {
    'id': 'primary',
    'size': {'width': 1920.0, 'height': 1080.0},
    'visiblePosition': {'dx': 0.0, 'dy': 0.0},
  };

  setUpAll(() => GStorage.setting = MemoryBox());
  tearDown(() {
    FocusManager.instance.removeEarlyKeyEventHandler(handleAppKeyEvent);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [window, background, screen]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('桌面窗口等待显示与聚焦；异步显示失败沿初始化 Future 返回', (tester) async {
    for (final fails in [false, true]) {
      final showing = Completer<Object?>();
      final methods = <String>[];
      Object? titleBarArguments;
      tester.binding.defaultBinaryMessenger
        ..setMockMethodCallHandler(background, (_) async => null)
        ..setMockMethodCallHandler(
          screen,
          (call) async => switch (call.method) {
            'getAllDisplays' => {
              'displays': [display],
            },
            'getPrimaryDisplay' => display,
            'getCursorScreenPoint' => {'dx': 100.0, 'dy': 100.0},
            _ => null,
          },
        )
        ..setMockMethodCallHandler(window, (call) async {
          methods.add(call.method);
          if (call.method == 'setTitleBarStyle') {
            titleBarArguments = call.arguments;
          }
          return switch (call.method) {
            'isMinimized' || 'isMaximized' || 'isFullScreen' => false,
            'show' => showing.future,
            _ => null,
          };
        });
      var completed = false;
      Object? failure;
      final initialized = initializePlatformWindow().then<void>(
        (_) {
          completed = true;
        },
        onError: (Object error) {
          failure = error;
        },
      );
      await tester.pump();
      expect(failure, isNull);
      expect(titleBarArguments, {
        'titleBarStyle': 'hidden',
        'windowButtonVisibility': false,
      });
      expect(methods, contains('show'));
      expect(completed, isFalse);
      expect(methods, isNot(contains('focus')));
      if (fails) {
        showing.completeError(PlatformException(code: 'show_failed'));
      } else {
        showing.complete(null);
      }
      await tester.pump();
      await initialized;
      if (fails) {
        expect(failure, isA<PlatformException>());
        expect(completed, isFalse);
        expect(methods, isNot(contains('focus')));
      } else {
        expect(failure, isNull);
        expect(completed, isTrue);
        expect(methods.last, 'focus');
      }
      expect(tester.takeException(), isNull);
    }
  }, skip: !Platform.isWindows);
}
