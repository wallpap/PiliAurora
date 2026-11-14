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
    for (final channel in [window, background, screen, SystemChannels.skia]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  testWidgets('窗口等待显示与聚焦、传递显示失败，绘制预算失败仍可启动', (tester) async {
    for (final (fails, budgetFailure) in [
      (false, null),
      (true, null),
      (false, PlatformException(code: 'budget_unavailable')),
      (false, MissingPluginException()),
    ]) {
      final showing = Completer<Object?>();
      final methods = <String>[];
      Object? titleBarArguments;
      tester.binding.defaultBinaryMessenger
        ..setMockMethodCallHandler(SystemChannels.skia, (call) async {
          expect(call.method, 'Skia.setResourceCacheMaxBytes');
          expect(call.arguments, 64 << 20);
          methods.add('rasterBudget');
          if (budgetFailure != null) throw budgetFailure;
          return true;
        })
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
      expect(methods.first, 'rasterBudget');
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
    // 预算失败会触发诊断通知的节流定时器。
    await tester.pump(const Duration(milliseconds: 250));
  }, skip: !Platform.isWindows);
}
