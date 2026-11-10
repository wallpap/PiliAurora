import 'dart:typed_data';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/theme_utils.dart';

import '../support/memory_box.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test('Android有符号Int32调色板同时生成明暗主题，并缓存确认结果', () async {
    GStorage.setting = MemoryBox({SettingBoxKey.dynamicColor: true});
    var calls = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      DynamicColorPlugin.channel,
      (_) async {
        calls++;
        return Int32List.fromList(
          List.generate(65, (i) => 0xff000000 | (i * 0x030303)),
        );
      },
    );
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DynamicColorPlugin.channel,
        null,
      ),
    );
    expect(await ThemeUtils.initPlatformState(), true);
    expect(await ThemeUtils.initPlatformState(), true);
    expect(calls, 1);
    final (light, dark) = ThemeUtils.getAllTheme();
    expect(light.brightness, Brightness.light);
    expect(dark.brightness, Brightness.dark);
  });
}
