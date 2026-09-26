import 'dart:math' show cos, sin;
import 'dart:ui' as ui;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:canvas_danmaku/utils/utils.dart' as canvas_danmaku;
import 'package:material_ui/material_ui.dart';

/// 在 canvas_danmaku 同步生成图片前，限制单条高级弹幕的栅格尺寸。
abstract final class DanmakuRenderGuard {
  static const maxSpecialImageBytes = 2 * 1024 * 1024;
  static const maxImageSide = 4096;

  static bool canRasterizeSpecial(
    SpecialDanmakuContentItem content,
    double devicePixelRatio,
    double strokeWidth,
    int fontWeight,
  ) {
    if (!devicePixelRatio.isFinite ||
        devicePixelRatio <= 0 ||
        !content.fontSize.isFinite ||
        content.fontSize <= 0 ||
        !strokeWidth.isFinite ||
        strokeWidth < 0) {
      return false;
    }

    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        fontSize: content.fontSize,
        fontWeight: FontWeight.values[fontWeight],
        fontFamily: canvas_danmaku.DmUtils.fontFamily,
        textDirection: TextDirection.ltr,
      ),
    )..addText(content.text);
    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
    final width = paragraph.maxIntrinsicWidth + strokeWidth;
    final height = paragraph.height + strokeWidth;
    paragraph.dispose();

    final matrix = content.matrix;
    final cosZ = matrix == null ? cos(content.rotateZ) : matrix[5];
    final sinZ = matrix == null ? sin(content.rotateZ) : matrix[1];
    final cosY = matrix == null ? 1.0 : matrix[10];
    final wx = width * cosZ * cosY;
    final wy = width * sinZ;
    final hx = -height * sinZ * cosY;
    final hy = height * cosZ;
    final pixelWidth = _range(0, wx, hx, wx + hx) * devicePixelRatio;
    final pixelHeight = _range(0, wy, hy, wy + hy) * devicePixelRatio;
    return pixelWidth.isFinite &&
        pixelHeight.isFinite &&
        pixelWidth > 0 &&
        pixelHeight > 0 &&
        pixelWidth <= maxImageSide &&
        pixelHeight <= maxImageSide &&
        pixelWidth * pixelHeight * 4 <= maxSpecialImageBytes;
  }

  static double _range(double a, double b, double c, double d) {
    final minAB = a < b ? a : b;
    final minCD = c < d ? c : d;
    final maxAB = a > b ? a : b;
    final maxCD = c > d ? c : d;
    return (maxAB > maxCD ? maxAB : maxCD) - (minAB < minCD ? minAB : minCD);
  }
}
