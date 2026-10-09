import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  test('normalizes source dimensions after display rotation', () {
    expect(
      VideoOutputSizePolicy.videoDisplaySize(
        const VideoParams(dw: 1920, dh: 1080, rotate: 0),
      ),
      (width: 1920, height: 1080),
    );
    expect(
      VideoOutputSizePolicy.videoDisplaySize(
        const VideoParams(dw: 1920, dh: 1080, rotate: 90),
      ),
      (width: 1080, height: 1920),
    );
    expect(
      VideoOutputSizePolicy.videoDisplaySize(
        const VideoParams(dw: 1920, dh: 1080, rotate: 270),
      ),
      (width: 1080, height: 1920),
    );
  });

  test('normalizes and validates physical display dimensions', () {
    expect(
      VideoOutputSizePolicy.physicalDisplaySize(const ui.Size(1920, 1080)),
      (
        width: 1920,
        height: 1080,
      ),
    );
    expect(
      VideoOutputSizePolicy.physicalDisplaySize(const ui.Size(1, 1)),
      isNull,
    );
  });

  test(
    'limits landscape and portrait sources while preserving their ratio',
    () {
      expect(
        VideoOutputSizePolicy.fitWithinLimit(
          source: (width: 3840, height: 2160),
          limit: (width: 1920, height: 1080),
        ),
        (width: 1920, height: 1080),
      );
      expect(
        VideoOutputSizePolicy.fitWithinLimit(
          source: (width: 2160, height: 3840),
          limit: (width: 1920, height: 1080),
        ),
        (width: 1080, height: 1920),
      );
    },
  );

  test('preserves smaller sources and leaves them unscaled', () {
    expect(
      VideoOutputSizePolicy.fitWithinLimit(
        source: (width: 1280, height: 720),
        limit: (width: 1920, height: 1080),
      ),
      (width: 1280, height: 720),
    );
    expect(
      VideoOutputSizePolicy.fitWithinLimit(
        source: (width: 1280, height: 720),
        limit: null,
      ),
      (width: 1280, height: 720),
    );
  });
}
