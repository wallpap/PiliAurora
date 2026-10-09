import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_speed.dart';
import 'package:pili_aurora/plugin/pl_player/utils/danmaku_options.dart';

void main() {
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pili-playback-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });
  group('播放器时序契约', () {
    test('实验性纹理缩放默认关闭，旧开关不启用新功能', () async {
      await GStorage.setting.put(SettingBoxKey.enableAndroidVideoOutputSize, true);
      expect(Pref.enableAndroidTextureScaling, isFalse);
      await GStorage.setting.put(SettingBoxKey.enableAndroidTextureScaling, true);
      expect(Pref.enableAndroidTextureScaling, isTrue);
      await GStorage.setting.put(SettingBoxKey.enableAndroidTextureScaling, false);
      expect(Pref.enableAndroidTextureScaling, isFalse);
      await GStorage.setting.delete(SettingBoxKey.enableAndroidTextureScaling);
      await GStorage.setting.delete(SettingBoxKey.enableAndroidVideoOutputSize);
    });
    test('所有 UI 倍速选项均为正数且包含 1x', () {
      final values = PlaySpeed.values.map((speed) => speed.value).toList();

      expect(values, contains(1.0));
      expect(values, everyElement(greaterThan(0)));
      expect(values, orderedEquals(<double>[
        0.5,
        0.75,
        1.0,
        1.25,
        1.5,
        1.75,
        2.0,
        3.0,
      ]));
    });

    test('倍速改变时滚动与固定弹幕的显示时长反向缩放', () {
      final normal = DanmakuOptions.get(notFullscreen: true, speed: 1.0);
      final doubleRate = DanmakuOptions.get(notFullscreen: true, speed: 2.0);
      final halfRate = DanmakuOptions.get(notFullscreen: true, speed: 0.5);

      expect(doubleRate.duration, closeTo(normal.duration / 2, 1e-9));
      expect(doubleRate.staticDuration, closeTo(normal.staticDuration / 2, 1e-9));
      expect(halfRate.duration, closeTo(normal.duration * 2, 1e-9));
      expect(halfRate.staticDuration, closeTo(normal.staticDuration * 2, 1e-9));
    });

    test('非全屏和全屏只影响字体，不破坏弹幕时序', () {
      final windowed = DanmakuOptions.get(notFullscreen: true, speed: 1.5);
      final fullscreen = DanmakuOptions.get(notFullscreen: false, speed: 1.5);

      expect(windowed.duration, fullscreen.duration);
      expect(windowed.staticDuration, fullscreen.staticDuration);
    });
  });
}

