import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  AndroidFixedSurfaceSize output() => AndroidFixedSurfaceSize(
    limitWidth: 2400,
    limitHeight: 1080,
  );

  test('smaller and equal sources keep their original dimensions', () {
    expect(output().resolve(1920, 1080), (width: 1920, height: 1080));
    expect(output().resolve(640, 360), (width: 640, height: 360));
    expect(output().resolve(2400, 1080), (width: 2400, height: 1080));
    expect(output().resolve(1000, 1000), (width: 1000, height: 1000));
  });

  test(
    'larger sources are capped to the baseline with source aspect preserved',
    () {
      expect(output().resolve(3840, 2160), (width: 1920, height: 1080));
      expect(output().resolve(4800, 2160), (width: 2400, height: 1080));
      expect(output().resolve(2560, 1080), (width: 2400, height: 1012));
      expect(output().resolve(2160, 2160), (width: 1080, height: 1080));
    },
  );

  test('portrait sources use the portrait baseline and never upscale', () {
    expect(output().resolve(1080, 1920), (width: 1080, height: 1920));
    expect(output().resolve(2160, 3840), (width: 1080, height: 1920));
  });

  test('output stays fixed through parameter updates until media reset', () {
    final fixed = output();
    expect(fixed.resolve(3840, 2160), (width: 1920, height: 1080));
    expect(fixed.resolve(1080, 1920), (width: 1920, height: 1080));
    expect(fixed.resolve(640, 360), (width: 1920, height: 1080));
    fixed.reset();
    expect(fixed.resolve(640, 360), (width: 640, height: 360));
  });

  test('invalid baseline keeps source size and invalid source is rejected', () {
    expect(AndroidFixedSurfaceSize().resolve(1280, 720), (
      width: 1280,
      height: 720,
    ));
    expect(() => output().resolve(0, 100), throwsArgumentError);
    expect(output().resolve(1, 100000), (width: 1, height: 2400));
  });
}
