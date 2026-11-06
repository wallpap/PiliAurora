import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/pages/video/widgets/detail_panels.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/utils/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.alexmercerind/media_kit_video');

  testWidgets('Windows 原生窗口放大前已提交全屏布局，保留播放器元素', (tester) async {
    GStorage.setting = await Hive.openBox(
      'fullscreen-setting',
      bytes: Uint8List(0),
    );
    GStorage.video = await Hive.openBox(
      'fullscreen-video',
      bytes: Uint8List(0),
    );
    GStorage.localCache = await Hive.openBox(
      'fullscreen-cache',
      bytes: Uint8List(0),
    );
    final controller = PlPlayerController.getInstance();
    addTearDown(() async {
      controller.volumeTimer?.cancel();
      await Hive.close();
    });
    final videoKey = GlobalKey();
    double? widthAtNativeEntry;
    var nativeEntries = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'Utils.EnterNativeFullscreen') {
        nativeEntries++;
        widthAtNativeEntry = videoKey.currentContext!.size!.width;
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Obx(
            () => Row(
              children: [
                Expanded(
                  child: ColoredBox(key: videoKey, color: Colors.black),
                ),
                VideoDetailOffstage(
                  offstage: controller.isFullScreen.value,
                  child: const SizedBox(
                    width: 300,
                    child: ColoredBox(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final original = tester.element(find.byKey(videoKey));
    final fullWidth = tester.getSize(find.byType(Scaffold)).width;
    final entering = controller.triggerFullScreen();
    expect(widthAtNativeEntry, isNull);
    await controller.triggerFullScreen();
    await tester.pump();
    await entering;
    expect(widthAtNativeEntry, fullWidth);
    expect(nativeEntries, 1);
    expect(tester.element(find.byKey(videoKey)), same(original));
    await controller.triggerFullScreen(status: false);
    await tester.pump();
    expect(controller.isFullScreen.value, isFalse);
    expect(tester.element(find.byKey(videoKey)), same(original));
  }, skip: !Platform.isWindows);
}
