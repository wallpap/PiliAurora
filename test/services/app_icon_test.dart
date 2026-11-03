import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/models/common/theme/app_icon_style.dart';
import 'package:pili_aurora/services/app_icon.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    GStorage.setting = await Hive.openBox('app_icon_test', bytes: Uint8List(0));
  });
  setUp(() async {
    await GStorage.setting.clear();
    Assets.iconStyle.value = AppIconStyle.chibi;
  });
  tearDownAll(Hive.close);

  test('首次启动与未知设置回退 Q 版；明暗主题均能解析', () async {
    for (final name in [null, 'unknown']) {
      await GStorage.setting.put(SettingBoxKey.appIconStyle, name);
      AppIcon.load();
      expect(Assets.iconStyle.value, AppIconStyle.chibi);
      for (final brightness in Brightness.values) {
        expect(
          Assets.themed(Assets.logo, brightness),
          brightness == Brightness.dark
              ? Assets.logoChibiDark
              : Assets.logoChibi,
        );
        expect(
          Assets.themed(Assets.logoIco, brightness),
          brightness == Brightness.dark
              ? Assets.logoChibiIcoDark
              : Assets.logoChibiIco,
        );
      }
    }
  });

  test('切换后持久化，重载恢复原头像并保持原有明暗资源', () async {
    await AppIcon.select(AppIconStyle.portrait);
    Assets.iconStyle.value = AppIconStyle.chibi;
    AppIcon.load();
    expect(Assets.iconStyle.value, AppIconStyle.portrait);
    expect(Assets.themed(Assets.logo, Brightness.light), Assets.logo);
    expect(Assets.themed(Assets.logo, Brightness.dark), Assets.logoDark);
    expect(Assets.themed(Assets.logoIco, Brightness.dark), Assets.logoIcoDark);
    await AppIcon.select(AppIconStyle.chibi);
    expect(GStorage.setting.get(SettingBoxKey.appIconStyle), 'chibi');
  });

  for (final (style, image, darkImage, ico, darkIco) in [
    (
      AppIconStyle.upright,
      Assets.logoUpright,
      Assets.logoUprightDark,
      Assets.logoUprightIco,
      Assets.logoUprightIcoDark,
    ),
    (
      AppIconStyle.tilted,
      Assets.logoTilted,
      Assets.logoTiltedDark,
      Assets.logoTiltedIco,
      Assets.logoTiltedIcoDark,
    ),
  ]) {
    test('${style.label}独立保存，重载后明暗资源均保持所选风格', () async {
      await AppIcon.select(style);
      expect(GStorage.setting.get(SettingBoxKey.appIconStyle), style.name);
      Assets.iconStyle.value = AppIconStyle.chibi;
      AppIcon.load();
      expect(Assets.iconStyle.value, style);
      for (final brightness in Brightness.values) {
        expect(
          Assets.themed(Assets.logo, brightness),
          brightness == Brightness.dark ? darkImage : image,
        );
        expect(
          Assets.themed(Assets.logoIco, brightness),
          brightness == Brightness.dark ? darkIco : ico,
        );
      }
    });
  }
}
