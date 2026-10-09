import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:media_kit/media_kit.dart' show VideoParams;

typedef VideoOutputSize = ({int width, int height});

/// Resolves display geometry and applies a physical-pixel output limit.
///
/// This policy is pure. Platform controllers own media lifecycle and native
/// output submission.
abstract final class VideoOutputSizePolicy {
  static VideoOutputSize? videoDisplaySize(VideoParams params) {
    final width = params.dw;
    final height = params.dh;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    final rawRotation = (params.rotate ?? 0) % 360;
    final rotation = rawRotation < 0 ? rawRotation + 360 : rawRotation;
    return rotation == 90 || rotation == 270
        ? (width: height, height: width)
        : (width: width, height: height);
  }

  static VideoOutputSize? physicalDisplaySize(ui.Size size) {
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 1 ||
        size.height <= 1) {
      return null;
    }
    return (width: size.width.round(), height: size.height.round());
  }

  static VideoOutputSize? fitWithinLimit({
    required VideoOutputSize? source,
    required VideoOutputSize? limit,
  }) {
    if (source == null || source.width <= 0 || source.height <= 0) return null;
    if (limit == null || limit.width <= 0 || limit.height <= 0) return source;

    final longSide = math.max(limit.width, limit.height);
    final shortSide = math.min(limit.width, limit.height);
    final boundWidth = source.width >= source.height ? longSide : shortSide;
    final boundHeight = source.width >= source.height ? shortSide : longSide;
    final scale = math.min(
      1.0,
      math.min(boundWidth / source.width, boundHeight / source.height),
    );
    if (scale >= 1) return source;
    return (
      width: math.max(1, (source.width * scale).floor()),
      height: math.max(1, (source.height * scale).floor()),
    );
  }
}
