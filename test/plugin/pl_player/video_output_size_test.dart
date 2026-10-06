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

  test('keeps the source aspect ratio when the source is smaller', () {
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

  test('Android portrait viewport retains the landscape source ratio', () {
    expect(
      calculateVideoOutputSize(
        logicalWidth: 360,
        logicalHeight: 640,
        devicePixelRatio: 3,
        sourceWidth: 3840,
        sourceHeight: 2160,
        preserveSourceAspectRatio: true,
      ),
      (width: 1080, height: 608),
    );
  });

  test('Android rotated portrait source stays inside a landscape viewport', () {
    expect(
      calculateVideoOutputSize(
        logicalWidth: 640,
        logicalHeight: 360,
        devicePixelRatio: 3,
        sourceWidth: 1080,
        sourceHeight: 1920,
        preserveSourceAspectRatio: true,
      ),
      (width: 608, height: 1080),
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
