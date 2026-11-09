import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/utils/fullscreen.dart';
import 'package:pili_aurora/utils/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('com.alexmercerind/media_kit_video');
  const channels = [
    native,
    MethodChannel('piliaurora/window_background'),
    MethodChannel('window_manager'),
  ];

  testWidgets('全屏模型：原生失败保留已确认状态，交接期间保留最新退出目标', (
    tester,
  ) async {
    GStorage.setting = await Hive.openBox(
      'fullscreen-model-setting',
      bytes: Uint8List(0),
    );
    GStorage.video = await Hive.openBox(
      'fullscreen-model-video',
      bytes: Uint8List(0),
    );
    GStorage.localCache = await Hive.openBox(
      'fullscreen-model-cache',
      bytes: Uint8List(0),
    );
    for (final channel in channels) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => null,
      );
    }
    final controller = PlPlayerController.getInstance();
    Future<void> reset() async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        native,
        (_) async => null,
      );
      await exitDesktopFullScreen();
      controller.isFullScreen.value = false;
    }

    addTearDown(() async {
      await reset();
      controller.volumeTimer?.cancel();
      for (final channel in channels) {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      }
      await Hive.close();
    });
    final observed = <bool>[];
    for (final scenario in [
      (entering: true, fail: true),
      (entering: false, fail: true),
      (entering: true, fail: false),
    ]) {
      if (!scenario.entering) {
        final entry = controller.triggerFullScreen();
        await tester.pumpAndSettle();
        await entry;
      }
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
        call,
      ) async {
        if (scenario.fail &&
            call.method ==
                (scenario.entering
                    ? 'Utils.EnterNativeFullscreen'
                    : 'Utils.ExitNativeFullscreen')) {
          throw PlatformException(code: 'model-fullscreen-failed');
        }
        return null;
      });

      final transition = controller.triggerFullScreen(
        status: scenario.entering,
      );
      final latest = scenario.fail
          ? null
          : controller.triggerFullScreen(status: false);
      await tester.pumpAndSettle();
      await transition;
      await latest;
      observed.add(controller.isFullScreen.value);
      await reset();
    }

    expect(observed, [false, true, false]);

    final calls = <String>[];
    var failNextEntry = true;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
      call,
    ) async {
      calls.add(call.method);
      if (call.method == 'Utils.EnterNativeFullscreen' && failNextEntry) {
        failNextEntry = false;
        throw PlatformException(code: 'retry-entry');
      }
      return null;
    });
    var transition = controller.triggerFullScreen();
    await tester.pumpAndSettle();
    await transition;
    expect(controller.isFullScreen.value, isFalse);
    expect(calls, ['Utils.EnterNativeFullscreen']);

    transition = controller.triggerFullScreen();
    await controller.triggerFullScreen();
    await tester.pumpAndSettle();
    await transition;
    expect(controller.isFullScreen.value, isTrue);
    expect(calls, [
      'Utils.EnterNativeFullscreen',
      'Utils.EnterNativeFullscreen',
    ]);
    await controller.triggerFullScreen();
    expect(calls, hasLength(2));
    await controller.triggerFullScreen(status: false);
    expect(controller.isFullScreen.value, isFalse);
    expect(calls.last, 'Utils.ExitNativeFullscreen');

    calls.clear();
    transition = controller.triggerFullScreen();
    var exitSettled = false;
    final reverse = controller.triggerFullScreen(status: false).then((_) {
      exitSettled = true;
    });
    expect(exitSettled, isFalse);
    await controller.triggerFullScreen(status: true);
    await tester.pumpAndSettle();
    await transition;
    await reverse;
    expect(controller.isFullScreen.value, isTrue);
    expect(calls, ['Utils.EnterNativeFullscreen']);
    await controller.triggerFullScreen(status: false);
    calls.clear();

    await controller.triggerFullScreen(inAppFullScreen: true);
    expect(controller.isFullScreen.value, isTrue);
    expect(calls, isEmpty);
    await controller.triggerFullScreen(status: false, inAppFullScreen: true);
    expect(controller.isFullScreen.value, isFalse);
    expect(calls, isEmpty);

    final exitStarted = Completer<void>();
    final exitGate = Completer<void>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
      call,
    ) async {
      if (call.method == 'Utils.ExitNativeFullscreen') {
        exitStarted.complete();
        await exitGate.future;
      }
      return null;
    });
    transition = controller.triggerFullScreen();
    var finishedExit = false;
    final exit = controller.triggerFullScreen(status: false).then((_) {
      finishedExit = true;
    });
    await tester.pumpAndSettle();
    await exitStarted.future;
    expect(finishedExit, isFalse);
    exitGate.complete();
    await tester.pumpAndSettle();
    await transition;
    await exit;
    expect(controller.isFullScreen.value, isFalse);
    await tester.pump(const Duration(milliseconds: 300));
  }, skip: !Platform.isWindows);
}
