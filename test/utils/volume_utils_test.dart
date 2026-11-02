import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/utils/volume_utils.dart';

void main() {
  test('细小滚动累积为整数百分比，并在外部音量变化后重新起算', () {
    final adjustment = VolumeScrollAdjustment();
    var current = .85;
    for (var i = 0; i < 4; i++) {
      current = adjustment.apply(current, -10);
    }
    expect(current, .86);
    expect(adjustment.apply(.5, 0), .5);
    expect(adjustment.apply(.99, -1000), 1);
  });

  test('比例按最近整数百分比归整并限制为 0～100%', () {
    for (final (input, expected) in [
      (0.9912, .99),
      (.854, .85),
      (.856, .86),
      (.825, .83),
      (0.0, 0.0),
      (1.0, 1.0),
      (1.999, 1.0),
    ]) {
      expect(roundVolumeRatio(input), expected);
      expect(roundVolumeRatio(expected), expected);
    }
    expect(volumePercent(.57), 57);
    expect(volumePercent(.85), 85);
  });

  test('历史音量配置读取时转换并回写，重复读取不重复写入', () {
    final settings = _Settings()..storedValues['volume'] = .9912;
    expect(readVolumePreference(settings, 'volume', defaultValue: 1), .99);
    expect(settings.storedValues['volume'], .99);
    expect(readVolumePreference(settings, 'volume', defaultValue: 1), .99);
    expect(settings.writes, 1);
    // 旧备份在当前会话恢复后，重新读取也会立即转换。
    settings.storedValues['volume'] = .856;
    expect(readVolumePreference(settings, 'volume', defaultValue: 1), .86);
    expect(settings.storedValues['volume'], .86);
    settings.storedValues['gain'] = 125.6;
    expect(
      readVolumePreference(
        settings,
        'gain',
        defaultValue: 100,
        percentage: true,
      ),
      100,
    );
    expect(settings.storedValues['gain'], 100.0);
    expect(readVolumePreference(settings, 'missing', defaultValue: 1), 1);
    expect(settings.storedValues.containsKey('missing'), isFalse);
  });
}

class _Settings implements Box<dynamic> {
  final storedValues = <dynamic, dynamic>{};
  var writes = 0;
  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      storedValues[key] ?? defaultValue;
  @override
  Future<void> put(dynamic key, dynamic value) async {
    writes++;
    storedValues[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
