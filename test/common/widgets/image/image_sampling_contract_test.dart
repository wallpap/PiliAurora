import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/src/image_sampling.dart';

void main() {
  for (final (fit, expectedWidth, expectedHeight) in [
    (BoxFit.cover, 200, 1600),
    (BoxFit.contain, 25, 200),
    (BoxFit.fitWidth, 200, 1600),
    (BoxFit.fitHeight, 25, 200),
    (BoxFit.fill, 200, 1600),
    (BoxFit.scaleDown, 25, 200),
    (BoxFit.none, 800, 6400),
  ]) {
    test('$fit retains the source sampling required by its visible crop', () {
      final size = ImageSampling.targetSize(
        sourceSize: const ui.Size(800, 6400),
        displaySize: const ui.Size(100, 100),
        devicePixelRatio: 2,
        fit: fit,
      );
      expect(size.width, expectedWidth);
      expect(size.height, expectedHeight);
    });
  }

  test('low resolution sources never get an enlarged pixel cache', () {
    final size = ImageSampling.targetSize(
      sourceSize: const ui.Size(16, 8),
      displaySize: const ui.Size(1200, 900),
      devicePixelRatio: 3,
      fit: BoxFit.cover,
    );
    expect(size.width, 16);
    expect(size.height, 8);
  });

  test('readable long content is not silently restricted to one megapixel', () {
    final size = ImageSampling.targetSize(
      sourceSize: const ui.Size(1200, 24000),
      displaySize: const ui.Size(400, 8000),
      devicePixelRatio: 2,
      fit: BoxFit.contain,
    );
    expect(size.width, 800);
    expect(size.height, 16000);
  });

  test('fractional physical dimensions round up instead of losing detail', () {
    final size = ImageSampling.targetSize(
      sourceSize: const ui.Size(2000, 1000),
      displaySize: const ui.Size(100.25, 50.125),
      devicePixelRatio: 1.5,
      fit: BoxFit.contain,
    );
    expect(size.width, 151);
    expect(size.height, 76);
  });
}
