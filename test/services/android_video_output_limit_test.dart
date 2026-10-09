import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/android_video_output_limit.dart';

void main() {
  test('uses physical display dimensions as the output limit', () {
    expect(
      AndroidVideoOutputLimit.resolve(
        displaySize: const Size(1080, 2400),
        devicePixelRatio: 3,
      ),
      (width: 2400, height: 1080),
    );
  });

  test('falls back to Android display dimensions when Flutter reports 1px', () {
    expect(
      AndroidVideoOutputLimit.resolve(
        displaySize: const Size(1, 1),
        devicePixelRatio: 3,
        fallbackLogicalSize: (800, 360),
      ),
      (width: 2400, height: 1080),
    );
  });

  test('leaves output uncapped when hardware dimensions are unavailable', () {
    expect(
      AndroidVideoOutputLimit.resolve(
        displaySize: const Size(1, 1),
        devicePixelRatio: 3,
      ),
      isNull,
    );
  });
}
