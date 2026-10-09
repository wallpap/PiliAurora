import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_size.dart';

void main() {
  test('converts the logical viewport to physical pixels', () {
    expect(
      calculateVideoOutputSize(
        logicalWidth: 1280,
        logicalHeight: 720,
        devicePixelRatio: 1.5,
      ),
      (width: 1920, height: 1080),
    );
  });

  test('caps a small source without changing the viewport aspect ratio', () {
    expect(
      calculateVideoOutputSize(
        logicalWidth: 1920,
        logicalHeight: 1080,
        devicePixelRatio: 1,
        sourceWidth: 1280,
        sourceHeight: 960,
      ),
      (width: 1280, height: 720),
    );
  });

  test('does not upscale a source smaller than the viewport', () {
    expect(
      calculateVideoOutputSize(
        logicalWidth: 1080,
        logicalHeight: 1920,
        devicePixelRatio: 3,
        sourceWidth: 1080,
        sourceHeight: 1920,
      ),
      (width: 1080, height: 1920),
    );
  });

  test('returns null for an invalid viewport', () {
    expect(
      calculateVideoOutputSize(
        logicalWidth: 0,
        logicalHeight: 720,
        devicePixelRatio: 1,
      ),
      isNull,
    );
  });
}
