import 'dart:io';

import 'package:pili_aurora/services/logger.dart';

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

  static Future<void> _pending = Future<void>.value();

  // 保存、原生确认和回滚共用队列，旧操作不能覆盖后发选择。
  static Future<void> select(AppIconStyle style) {
    final result = _pending.then((_) => _select(style));
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static Future<void> _select(AppIconStyle style) async {
    final previous = Assets.iconStyle.value;
    await GStorage.setting.put(SettingBoxKey.appIconStyle, style.name);
    try {
      if (Platform.isAndroid) {
        await channel.invokeMethod<void>('setIcon', style.name);
      }
    } catch (error, stack) {
      try {
        await GStorage.setting.put(SettingBoxKey.appIconStyle, previous.name);
      } catch (rollbackError, rollbackStack) {
        logger.w(
          '恢复图标偏好失败',
          error: rollbackError.runtimeType,
          stackTrace: rollbackStack,
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
    Assets.iconStyle.value = style;
  }

  /// 备份恢复或清除应用数据后，让桌面入口与本次加载的偏好一致。
  static Future<void> syncLauncher() {
    final result = _pending.then((_) async {
      if (Platform.isAndroid) {
        await channel.invokeMethod<void>(
          'setIcon',
          Assets.iconStyle.value.name,
        );
      }
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
