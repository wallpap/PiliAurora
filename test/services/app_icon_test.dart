import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/models/common/theme/app_icon_style.dart';
import 'package:pili_aurora/services/app_icon.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../support/memory_box.dart';

class _DelayedSettings extends MemoryBox<dynamic> {
  Completer<void>? gate;
  final writes = <String>[];
  bool fail = false;
  @override
  Future<void> put(dynamic key, dynamic value) async {
    writes.add(value as String);
    if (writes.length == 1) {
      await gate?.future;
      if (fail) throw StateError('storage failure');
    }
    await super.put(key, value);
  }
}

void main() {
  final settings = _DelayedSettings();
  setUpAll(() => GStorage.setting = settings);
  setUp(() {
    settings
      ..data.clear()
      ..writes.clear()
      ..gate = null
      ..fail = false;
  });
  tearDown(() => Assets.iconStyle.value = AppIconStyle.chibi);

  test('并发选择串行保存，确认值按选择顺序推进', () async {
    settings.gate = Completer<void>();
    try {
      final first = AppIcon.select(AppIconStyle.portrait);
      final second = AppIcon.select(AppIconStyle.chibi);
      await Future<void>.delayed(Duration.zero);
      expect(settings.writes, ['portrait']);
      expect(Assets.iconStyle.value, AppIconStyle.chibi);
      settings.gate!.complete();
      await Future.wait([first, second]);
      expect(settings.writes, ['portrait', 'chibi']);
      expect(Assets.iconStyle.value, AppIconStyle.chibi);
      expect(settings.data[SettingBoxKey.appIconStyle], 'chibi');
    } finally {
      settings.fail = false;
    }
  });

  test('前次保存失败交付原错误，后发选择继续完成', () async {
    settings
      ..gate = Completer<void>()
      ..fail = true;
    try {
      final first = AppIcon.select(AppIconStyle.chibi);
      final failure = expectLater(first, throwsStateError);
      final second = AppIcon.select(AppIconStyle.portrait);
      settings.gate!.complete();
      await failure;
      await second;
      expect(Assets.iconStyle.value, AppIconStyle.portrait);
      expect(settings.data[SettingBoxKey.appIconStyle], 'portrait');
    } finally {
      settings.fail = false;
    }
  });

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
