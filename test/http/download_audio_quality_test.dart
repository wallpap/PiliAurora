import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/download.dart';

void main() {
  test('音频画质按精确匹配、向下降级、192K及首项顺序选择', () {
    for (final (available, preferred, expected) in [
      ([30280, 30251, 30216], 30251, 30251),
      ([30280, 30216], 30232, 30216),
      ([30251, 30280], 30216, 30280),
      ([30251, 30232], 30216, 30251),
    ]) {
      expect(
        DownloadHttp.selectAudioQuality(available, preferred),
        expected,
        reason: 'available=$available, preferred=$preferred',
      );
    }
  });
}
