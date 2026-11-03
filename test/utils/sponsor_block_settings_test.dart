import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/models/common/sponsor_block/segment_type.dart';
import 'package:pili_aurora/models/common/sponsor_block/skip_type.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

void main() {
  setUpAll(() async {
    GStorage.setting = await Hive.openBox<dynamic>(
      'sponsor-settings',
      bytes: Uint8List(0),
    );
  });
  tearDownAll(() => GStorage.setting.close());
  setUp(() => GStorage.setting.clear());

  test('旧数组升级保留类别行为和颜色，不自动启用新增分类', () async {
    await GStorage.setting.put(
      SettingBoxKey.blockSettings,
      List.generate(11, (i) => i % SkipType.values.length),
    );
    await GStorage.setting.put(
      SettingBoxKey.blockColor,
      List.generate(11, (i) => (0x101010 + i).toRadixString(16)),
    );
    final settings = {
      for (final entry in Pref.blockSettings) entry.first.name: entry.second,
    };
    expect(settings['sponsor'], SkipType.alwaysSkip);
    expect(settings['music_offtopic'], SkipType.alwaysSkip);
    expect(settings['jumpscare'], SkipType.disable);
    final music = SegmentType.values.singleWhere(
      (v) => v.name == 'music_offtopic',
    );
    expect(Pref.blockColor[music.index], const Color(0xff10101a));
  });

  test('按名称保存的选择不依赖分类位置，非法值单项回退', () async {
    await GStorage.setting.put(SettingBoxKey.blockSettings, {
      'sponsor': SkipType.disable.index,
      'music_offtopic': SkipType.showOnly.index,
      'jumpscare': SkipType.skipManually.index,
      'intro': 99,
    });
    await GStorage.setting.put(SettingBoxKey.blockColor, {
      'sponsor': '123456',
      'music_offtopic': 'abcdef',
      'intro': 'bad-color',
    });
    final settings = {
      for (final entry in Pref.blockSettings) entry.first.name: entry.second,
    };
    expect(settings['sponsor'], SkipType.disable);
    expect(settings['music_offtopic'], SkipType.showOnly);
    expect(settings['jumpscare'], SkipType.skipManually);
    expect(settings['intro'], SkipType.skipOnce);
    expect(Pref.blockColor[SegmentType.sponsor.index], const Color(0xff123456));
    expect(Pref.blockColor[SegmentType.intro.index], SegmentType.intro.color);
  });

  test('新安装启用惊吓自动处理，分类支持静音和手动跳过', () {
    final category = SegmentType.values.singleWhere(
      (v) => v.name == 'jumpscare',
    );
    expect(Pref.blockSettings[category.index].second, SkipType.alwaysSkip);
    expect(category.toActionType.map((a) => a.name), ['mute', 'skip']);
  });
}
