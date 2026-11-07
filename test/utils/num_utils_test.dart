import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/utils/num_utils.dart';

void main() {
  test('missing optional counts return zero without warning records', () {
    final before = Diagnostics.instance.recentLogs.length;
    for (final input in ['', '  ', '-', ' - ']) {
      expect(NumUtils.parseNum(input), 0);
    }
    expect(Diagnostics.instance.recentLogs.length, before);
    expect(NumUtils.parseNum('1.2万'), 12000);
  });
  test('parseNum handles units and malformed input without exceptions', () {
    for (final entry in {
      '': 0,
      '  - ': 0,
      'invalid': 0,
      '.': 0,
      '1.2.3万': 0,
      ' 42 ': 42,
      '1.5千': 1500,
      '2.34万次播放': 23400,
      '1.2亿': 120000000,
      '播放量：123': 123,
      '9' * 400: 0,
    }.entries) {
      expect(NumUtils.parseNum(entry.key), entry.value, reason: entry.key);
    }
  });
}
