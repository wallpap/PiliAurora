import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/models/common/theme/app_icon_style.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

abstract final class AppIcon {
  static const channel = MethodChannel('piliaurora/app_icon');

  static void load() {
    final name = GStorage.setting.get(SettingBoxKey.appIconStyle);
    Assets.iconStyle.value = AppIconStyle.values.firstWhere(
      (style) => style.name == name,
      orElse: () => AppIconStyle.chibi,
    );
  }

  static Future<void> select(AppIconStyle style) async {
    final previous = Assets.iconStyle.value;
    await GStorage.setting.put(SettingBoxKey.appIconStyle, style.name);
    try {
      if (Platform.isAndroid) {
        await channel.invokeMethod<void>('setIcon', style.name);
      }
    } catch (_) {
      await GStorage.setting.put(SettingBoxKey.appIconStyle, previous.name);
      rethrow;
    }
    Assets.iconStyle.value = style;
  }

  /// 备份恢复或清除应用数据后，让桌面入口与本次加载的偏好一致。
  static Future<void> syncLauncher() async {
    if (Platform.isAndroid) {
      await channel.invokeMethod<void>('setIcon', Assets.iconStyle.value.name);
    }
  }
}
