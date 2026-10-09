import 'dart:math' as math;

typedef VideoOutputSize = ({int width, int height});

VideoOutputSize? calculateVideoOutputSize({
  required double logicalWidth,
  required double logicalHeight,
  required double devicePixelRatio,
  int? sourceWidth,
  int? sourceHeight,
}) {
  if (!logicalWidth.isFinite ||
      !logicalHeight.isFinite ||
      !devicePixelRatio.isFinite ||
      logicalWidth <= 0 ||
      logicalHeight <= 0 ||
      devicePixelRatio <= 0) {
    return null;
  }

  final requestedWidth = (logicalWidth * devicePixelRatio)
      .round()
      .clamp(1, 0x7fffffff)
      .toInt();
  final requestedHeight = (logicalHeight * devicePixelRatio)
      .round()
      .clamp(1, 0x7fffffff)
      .toInt();

  var width = requestedWidth;
  var height = requestedHeight;
  if (sourceWidth case final sourceWidth? when sourceWidth > 0) {
    if (sourceHeight case final sourceHeight? when sourceHeight > 0) {
      final scale = math.min(
        1.0,
        math.min(
          sourceWidth / requestedWidth,
          sourceHeight / requestedHeight,
        ),
      );
      width = math.max(1, (requestedWidth * scale).round()).toInt();
      height = math.max(1, (requestedHeight * scale).round()).toInt();
    }
  }

  return (width: width, height: height);
}

VideoOutputSize? limitVideoOutputSize({
  required VideoOutputSize? source,
  required VideoOutputSize? limit,
}) {
  if (source == null || source.width <= 0 || source.height <= 0) return null;
  if (limit == null || limit.width <= 0 || limit.height <= 0) {
    return source;
  }

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
