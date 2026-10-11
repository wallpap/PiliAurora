import 'dart:math' as math;

import 'package:flutter/widgets.dart';

enum DesktopPlaybackLayout { grid, cascade }

/// 窗口排列使用显示器工作区的逻辑坐标，包含副屏的负坐标。
abstract final class DesktopPlaybackGeometry {
  static Rect fit(Rect bounds, Rect workArea) {
    final width = bounds.width
        .clamp(
          math.min(320.0, workArea.width),
          workArea.width,
        )
        .toDouble();
    final height = bounds.height
        .clamp(
          math.min(180.0, workArea.height),
          workArea.height,
        )
        .toDouble();
    return Rect.fromLTWH(
      bounds.left.clamp(workArea.left, workArea.right - width),
      bounds.top.clamp(workArea.top, workArea.bottom - height),
      width,
      height,
    );
  }

  static List<Rect> arrange(
    int count,
    Rect workArea,
    DesktopPlaybackLayout layout,
  ) {
    if (count == 0) return const [];
    if (layout == DesktopPlaybackLayout.cascade) {
      final size = Size(
        math.min(640, workArea.width),
        math.min(400, workArea.height),
      );
      return List.generate(
        count,
        (index) => fit(
          Rect.fromLTWH(
            workArea.left + index * 32,
            workArea.top + index * 32,
            size.width,
            size.height,
          ),
          workArea,
        ),
      );
    }
    final columns = math
        .sqrt(count * workArea.width / workArea.height * 9 / 16)
        .ceil()
        .clamp(1, count);
    final rows = (count / columns).ceil();
    final width = workArea.width / columns;
    final height = workArea.height / rows;
    return List.generate(
      count,
      (index) => Rect.fromLTWH(
        workArea.left + index % columns * width,
        workArea.top + index ~/ columns * height,
        width,
        height,
      ),
    );
  }
}
