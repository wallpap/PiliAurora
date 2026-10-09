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
