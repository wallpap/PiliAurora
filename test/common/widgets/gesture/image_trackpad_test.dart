import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/common/widgets/gesture/image_horizontal_drag_gesture_recognizer.dart';
import 'package:pili_aurora/utils/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pili-trackpad-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  for (final horizontal in [true, false]) {
    testWidgets('trackpad accepts horizontal image paging: $horizontal', (
      tester,
    ) async {
      var starts = 0;
      final recognizer = ImageHorizontalDragGestureRecognizer()
        ..onStart = (_) {
          starts++;
        }
        ..onUpdate = (_) {}
        ..onEnd = (_) {};
      addTearDown(recognizer.dispose);
      final verticalRecognizer = VerticalDragGestureRecognizer()
        ..onStart = (_) {}
        ..onUpdate = (_) {}
        ..onEnd = (_) {};
      addTearDown(verticalRecognizer.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Listener(
            onPointerPanZoomStart: (event) {
              recognizer
                ..setAtBothEdges()
                ..addPointerPanZoom(event);
              verticalRecognizer.addPointerPanZoom(event);
            },
            child: const ColoredBox(color: Color(0xFF000000)),
          ),
        ),
      );
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      const origin = Offset(100, 100);
      await gesture.panZoomStart(origin);
      expect(recognizer.initialPosition, origin);
      await gesture.panZoomUpdate(
        origin,
        pan: horizontal ? const Offset(100, 0) : const Offset(30, 100),
      );
      await gesture.panZoomEnd();
      expect(starts, horizontal ? 1 : 0);
      // 下一次触控板手势需重新建立初始位置和边界状态。
      final nextGesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await nextGesture.panZoomStart(origin);
      await nextGesture.panZoomUpdate(origin, pan: const Offset(100, 0));
      await nextGesture.panZoomEnd();
      expect(starts, horizontal ? 2 : 1);
      expect(tester.takeException(), isNull);
    });
  }
}
