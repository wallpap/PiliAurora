import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/desktop_playback_layout.dart';

void main() {
  const workArea = Rect.fromLTWH(-1920, 40, 1920, 1040);
  test('网格排列覆盖全部窗口，且保持在副屏工作区内', () {
    for (var count = 1; count <= 12; count++) {
      final bounds = DesktopPlaybackGeometry.arrange(
        count,
        workArea,
        DesktopPlaybackLayout.grid,
      );
      expect(bounds, hasLength(count));
      for (var i = 0; i < count; i++) {
        expect(workArea.intersect(bounds[i]), bounds[i]);
        for (var j = i + 1; j < count; j++) {
          expect(bounds[i].overlaps(bounds[j]), isFalse);
        }
      }
    }
  });
  test('恢复失效位置及过大的窗口，层叠窗口不越出工作区', () {
    final restored = DesktopPlaybackGeometry.fit(
      const Rect.fromLTWH(4000, -4000, 4000, 2000),
      workArea,
    );
    expect(restored, workArea);
    final bounds = DesktopPlaybackGeometry.arrange(
      40,
      workArea,
      DesktopPlaybackLayout.cascade,
    );
    for (final bound in bounds) {
      expect(workArea.intersect(bound), bound);
    }
    expect(bounds[1].topLeft - bounds[0].topLeft, const Offset(32, 32));
    expect(
      DesktopPlaybackGeometry.arrange(0, workArea, DesktopPlaybackLayout.grid),
      isEmpty,
    );
  });
}
