import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/models/common/theme/app_icon_style.dart';
import 'package:pili_aurora/services/app_icon.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../support/memory_box.dart';

void main() {
  setUpAll(() => GStorage.setting = MemoryBox<dynamic>());
  setUp(() => GStorage.setting.clear());
  tearDown(() => Assets.iconStyle.value = AppIconStyle.chibi);

  test('所有风格切换后立即生效，持久化并可重载', () async {
    for (final style in AppIconStyle.values) {
      // 重载前先改成不同值，避免 load 未生效时仍能通过。
      final other = style == AppIconStyle.chibi
          ? AppIconStyle.portrait
          : AppIconStyle.chibi;
      Assets.iconStyle.value = other;
      await AppIcon.select(style);
      expect(Assets.iconStyle.value, style, reason: style.name);
      expect(GStorage.setting.get(SettingBoxKey.appIconStyle), style.name);
      Assets.iconStyle.value = other;
      AppIcon.load();
      expect(Assets.iconStyle.value, style, reason: style.name);
    }
  });

  test('缺失及未知配置均重置已有风格为默认值', () async {
    for (final name in [null, 'unknown']) {
      if (name != null) {
        await GStorage.setting.put(SettingBoxKey.appIconStyle, name);
      }
      Assets.iconStyle.value = AppIconStyle.portrait;
      AppIcon.load();
      expect(Assets.iconStyle.value, AppIconStyle.chibi, reason: '$name');
    }
  });
}
