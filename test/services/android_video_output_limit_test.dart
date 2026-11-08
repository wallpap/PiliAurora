import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/android_video_output_limit.dart';

void main() {
  test('有效物理尺寸优先，逻辑备用尺寸按 DPR 换算，不可用时不限制输出', () {
    for (final (display, dpr, fallback, expected)
        in <(Size, double, (int, int)?, ({int width, int height})?)>[
          (const Size(1080, 2400), 3, (800, 600), (width: 2400, height: 1080)),
          (const Size(1, 1), 3, (800, 360), (width: 2400, height: 1080)),
          (const Size(1, 1), 3, null, null),
          (Size.zero, 0, (800, 360), null),
          (Size.zero, double.nan, (800, 360), null),
          (Size.zero, 3, (0, 360), null),
        ]) {
      expect(
        AndroidVideoOutputLimit.resolve(
          displaySize: display,
          devicePixelRatio: dpr,
          fallbackLogicalSize: fallback,
        ),
        expected,
        reason: 'display=$display, dpr=$dpr, fallback=$fallback',
      );
    }
  });
}
