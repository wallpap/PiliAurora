import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/utils/storage_key.dart';

/// 设置备份的格式、校验与替换规则集中在这里，不依赖页面或全局存储初始化。
class SettingsBackup {
  const SettingsBackup({required this._setting, required this._video});

  final Box<dynamic> _setting;
  final Box<dynamic> _video;
  static const _equality = DeepCollectionEquality();
  static const _encoder = JsonEncoder.withIndent('    ');

  /// 保持既有 setting/video JSON 格式，包含视频偏好但不包含账号数据。
  String exportJson() {
    final settings = _setting.toMap()
      ..remove(LegacySettingBoxKey.androidFullscreenCalibration);
    return _encoder.convert({'setting': settings, 'video': _video.toMap()});
  }

  Future<void> restoreJson(String data) => restoreMap(jsonDecode(data));

  Future<void> restoreMap(Object? document) async {
    if (document is! Map) {
      throw const FormatException('设置备份必须是 JSON 对象');
    }
    // 所有分区都在第一次写入之前校验；不完整备份不会先清空另一分区。
    final setting = _section(document, 'setting')
      ..remove(LegacySettingBoxKey.androidFullscreenCalibration);
    final video = _section(document, 'video');
    final plans = [_plan(_setting, setting), _plan(_video, video)];

    // 先写入变更，再删除过期键。任一写入失败时不主动删除旧设置。
    // Hive 没有跨 Box 事务，这里不宣称两个分区可以原子提交。
    await Future.wait(
      plans.map((plan) async {
        if (plan.changes.isNotEmpty) await plan.box.putAll(plan.changes);
      }),
    );
    await Future.wait(
      plans.map((plan) async {
        if (plan.removed.isNotEmpty) await plan.box.deleteAll(plan.removed);
      }),
    );
  }

  Map<dynamic, dynamic> _section(Map document, String name) {
    final value = document[name];
    if (value is! Map ||
        value.keys.any((key) => key is! String && key is! int)) {
      throw FormatException('设置备份的 $name 分区必须是有效的键值对象');
    }
    return Map<dynamic, dynamic>.of(value);
  }

  ({Box<dynamic> box, Map<dynamic, dynamic> changes, List<dynamic> removed})
  _plan(
    Box<dynamic> box,
    Map<dynamic, dynamic> replacement,
  ) {
    final current = box.toMap();
    return (
      box: box,
      changes: {
        for (final entry in replacement.entries)
          if (!current.containsKey(entry.key) ||
              !_equality.equals(current[entry.key], entry.value))
            entry.key: entry.value,
      },
      removed: current.keys
          .where((key) => !replacement.containsKey(key))
          .toList(),
    );
  }
}
