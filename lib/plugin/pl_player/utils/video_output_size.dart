import 'dart:math' as math;

typedef VideoOutputSize = ({int width, int height});

bool isPortraitVideo(VideoOutputSize? source) =>
    source != null && source.width > 0 && source.height > source.width;

VideoOutputSize? calculateVideoOutputSize({
  required double logicalWidth,
  required double logicalHeight,
  required double devicePixelRatio,
  int? sourceWidth,
  int? sourceHeight,
  bool preserveSourceAspectRatio = false,
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
      if (preserveSourceAspectRatio) {
        // Android 的 Rect 仍描述源画面；纹理需保持相同比例，不能把视口黑边
        // 烘进纹理后再由 Flutter 按源比例缩放。
        final scale = math.min(
          1.0,
          math.min(
            requestedWidth / sourceWidth,
            requestedHeight / sourceHeight,
          ),
        );
        return (
          width: math.max(1, (sourceWidth * scale).round()),
          height: math.max(1, (sourceHeight * scale).round()),
        );
      }
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
