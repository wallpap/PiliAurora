import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/models/common/theme/theme_color_type.dart';
import 'package:pili_aurora/utils/extension/theme_ext.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/theme_utils.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pili-theme-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
  });

  setUp(() async {
    await GStorage.setting.clear();
    await GStorage.setting.put(SettingBoxKey.dynamicColor, false);
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      DynamicColorPlugin.channel,
      null,
    );
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('builds both themes without importing or mounting the application', () {
    final (light, dark) = ThemeUtils.getAllTheme();
    expect(light.brightness, Brightness.light);
    expect(dark.brightness, Brightness.dark);
    expect(
      light.colorScheme.primary,
      colorThemeTypes.first.color.asColorSchemeSeed(Pref.schemeVariant).primary,
    );
    expect(ThemeUtils.lightTheme, same(light));
    expect(ThemeUtils.darkTheme, same(dark));
    ThemeUtils.themeMode = ThemeMode.light;
    expect(ThemeUtils.theme, same(light));
    ThemeUtils.themeMode = ThemeMode.dark;
    expect(ThemeUtils.theme, same(dark));
  });

  test(
    'custom colors regenerate both schemes without a platform call',
    () async {
      const seed = Color(0xFF0055AA);
      await GStorage.setting.put(SettingBoxKey.customColor, seed.toARGB32());
      final (light, dark) = ThemeUtils.getAllTheme();
      expect(
        light.colorScheme.primary,
        seed.asColorSchemeSeed(Pref.schemeVariant).primary,
      );
      expect(
        dark.colorScheme.primary,
        seed.asColorSchemeSeed(Pref.schemeVariant, Brightness.dark).primary,
      );
    },
  );
  test(
    'dynamic colors handle absence, accent fallback and caching',
    () async {
      final calls = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DynamicColorPlugin.channel,
        (call) async {
          calls.add(call.method);
          return null;
        },
      );
      await GStorage.setting.put(SettingBoxKey.dynamicColor, true);
      expect(await ThemeUtils.initPlatformState(), isFalse);
      expect(Pref.dynamicColor, isFalse);
      expect(calls, [
        DynamicColorPlugin.methodName,
        DynamicColorPlugin.accentColorMethodName,
      ]);
      calls.clear();
      await GStorage.setting.put(SettingBoxKey.dynamicColor, true);
      const accent = Color(0xFF6750A4);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DynamicColorPlugin.channel,
        (call) async {
          calls.add(call.method);
          if (call.method == DynamicColorPlugin.methodName) {
            throw PlatformException(code: 'unavailable');
          }
          return accent.toARGB32();
        },
      );
      expect(await ThemeUtils.initPlatformState(), isTrue);
      expect(await ThemeUtils.initPlatformState(), isTrue);
      expect(calls, [
        DynamicColorPlugin.methodName,
        DynamicColorPlugin.accentColorMethodName,
      ]);
      final (light, dark) = ThemeUtils.getAllTheme();
      expect(
        light.colorScheme.primary,
        accent.asColorSchemeSeed(Pref.schemeVariant).primary,
      );
      expect(
        dark.colorScheme.primary,
        accent.asColorSchemeSeed(Pref.schemeVariant, Brightness.dark).primary,
      );
    },
  );
}
