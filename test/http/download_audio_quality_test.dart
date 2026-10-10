import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/download.dart';
import 'package:pili_aurora/models/common/video/audio_quality.dart';

void main() {
  group('DownloadHttp.selectAudioQuality', () {
    test('prefers an exact Hi-Res match', () {
      expect(
        DownloadHttp.selectAudioQuality([30280, 30251, 30216], 30251),
        30251,
      );
    });

    test('chooses the highest available quality at or below the preference', () {
      expect(
        DownloadHttp.selectAudioQuality([30280, 30216], 30232),
        30216,
      );
    });

    test('uses 192K when no lower quality is available and 192K exists', () {
      expect(
        DownloadHttp.selectAudioQuality([30251, 30280], 30216),
        AudioQuality.k192.code,
      );
    });

    test('falls back to the first available item when 192K is absent', () {
      expect(
        DownloadHttp.selectAudioQuality([30251, 30232], 30216),
        30251,
      );
    });
  });
}
