import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/services/android_video_calibration.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

void main() {
  testWidgets(
    'default fullscreen display is saved once; import only changes on manual calibration',
    (tester) async {
      await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'fullscreen-calibration-',
        );
        Hive.init(directory.path);
        GStorage.setting = await Hive.openBox('setting');
        addTearDown(() async {
          await Hive.close();
          await directory.delete(recursive: true);
        });
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.display.resetSize);
        tester.view.display.size = const Size(1080, 2400);
        tester.view.physicalSize = const Size(
          400,
          300,
        ); // PiP must not become the baseline.
        expect(await AndroidVideoCalibration.ensure(), (
          width: 2400,
          height: 1080,
        ));
        tester.view.display.size = const Size(2400, 1080);
        tester.view.physicalSize = const Size(1080, 2400);
        expect(await AndroidVideoCalibration.ensure(), (
          width: 2400,
          height: 1080,
        ));
        await GStorage.setting.put(SettingBoxKey.androidFullscreenCalibration, {
          'width': 3840,
          'height': 2160,
        });
        expect(await AndroidVideoCalibration.ensure(), (
          width: 3840,
          height: 2160,
        ));
        expect(await AndroidVideoCalibration.recalibrate(view: tester.view), (
          width: 2400,
          height: 1080,
        ));
        tester.view.display.size = Size.zero;
        await expectLater(
          AndroidVideoCalibration.recalibrate(view: tester.view),
          throwsStateError,
        );
        expect(AndroidVideoCalibration.saved, (width: 2400, height: 1080));
      });
    },
  );
}
