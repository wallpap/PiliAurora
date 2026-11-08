import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/utils/hardware_video_configuration.dart';
import 'package:pili_aurora/plugin/pl_player/models/hwdec_type.dart';

void main() {
  test('Windows 输出限制大源，保留小源，未知尺寸保持自动', () {
    for (final (source, expected) in <(VideoOutputSize?, VideoOutputSize?)>[
      ((width: 3840, height: 2160), (width: 2560, height: 1440)),
      ((width: 1920, height: 1080), (width: 1920, height: 1080)),
      (null, null),
      ((width: 0, height: 0), null),
    ]) {
      final configuration = hardwareVideoConfiguration(
        enabled: true,
        configured: 'auto-copy',
        windowsSourceSize: source,
        windowsOutputLimit: (width: 2560, height: 1440),
      );
      expect(
        (configuration.width, configuration.height),
        (expected?.width, expected?.height),
        reason: '$source',
      );
    }
  });

  test(
    'disabling hardware acceleration falls back to software decoding only',
    () {
      final configuration = hardwareVideoConfiguration(
        enabled: false,
        configured: HwDecType.kHwdec,
      );

      expect(configuration.enableHardwareAcceleration, isFalse);
      expect(configuration.hwdec, 'no');
    },
  );
  test('Windows auto-copy does not append incompatible direct backends', () {
    final configuration = hardwareVideoConfiguration(
      enabled: true,
      configured: 'auto-copy',
    );

    expect(configuration.hwdec, 'auto-copy,no');
    expect(configuration.androidAttachSurfaceAfterVideoParameters, isTrue);
  }, skip: !Platform.isWindows);

  test('defers output detection through the native fixed-size policy', () {
    VideoOutputSize? limit;
    var reads = 0;
    final configuration = hardwareVideoConfiguration(
      enabled: true,
      configured: 'mediacodec',
      androidOutputLimit: () {
        reads++;
        return limit;
      },
    );
    final output = AndroidFixedSurfaceSize(
      limitWidth: configuration.androidOutputLimitWidth,
      limitHeight: configuration.androidOutputLimitHeight,
      readLimit: configuration.androidOutputLimit,
    );
    expect(reads, 0);
    limit = (width: 2510, height: 1156);
    expect(output.resolve(3794, 2160), (width: 2030, height: 1156));
    expect(reads, 1);
  });
}
