import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  test('视频显示尺寸随旋转归一化，物理显示尺寸须有效', () {
    for (final (rotation, expected) in [
      (0, (width: 1920, height: 1080)),
      (90, (width: 1080, height: 1920)),
      (270, (width: 1080, height: 1920)),
    ]) {
      expect(
        VideoOutputSizePolicy.videoDisplaySize(
          VideoParams(dw: 1920, dh: 1080, rotate: rotation),
        ),
        expected,
        reason: 'rotation=$rotation',
      );
    }
    expect(
      VideoOutputSizePolicy.physicalDisplaySize(const ui.Size(1920, 1080)),
      (width: 1920, height: 1080),
    );
    expect(
      VideoOutputSizePolicy.physicalDisplaySize(const ui.Size(1, 1)),
      isNull,
    );
  });

  test('限幅保持横竖屏比例，不放大小源，无限制时保留原始尺寸', () {
    for (final (source, limit, expected) in [
      (
        (width: 3840, height: 2160),
        (width: 1920, height: 1080),
        (width: 1920, height: 1080),
      ),
      (
        (width: 2160, height: 3840),
        (width: 1920, height: 1080),
        (width: 1080, height: 1920),
      ),
      (
        (width: 1280, height: 720),
        (width: 1920, height: 1080),
        (width: 1280, height: 720),
      ),
      ((width: 1280, height: 720), null, (width: 1280, height: 720)),
    ]) {
      expect(
        VideoOutputSizePolicy.fitWithinLimit(source: source, limit: limit),
        expected,
        reason: 'source=$source, limit=$limit',
      );
    }
  });
}
