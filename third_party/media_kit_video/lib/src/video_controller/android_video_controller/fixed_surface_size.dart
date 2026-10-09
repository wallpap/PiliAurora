import 'dart:math' as math;

/// 全屏基准来自设备校准，不来自当前 viewport。一个媒体只确定一次输出。
/// 基准沿长/短边与源对齐；超过基准的源等比缩小，较小的源保持原尺寸。
class AndroidFixedSurfaceSize {
  AndroidFixedSurfaceSize({this.fullscreenWidth, this.fullscreenHeight});
  final int? fullscreenWidth;
  final int? fullscreenHeight;
  ({int width, int height})? _size;
  ({int width, int height})? get size => _size;

  ({int width, int height}) resolve(int sourceWidth, int sourceHeight) {
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      throw ArgumentError('Invalid source size: ${sourceWidth}x$sourceHeight');
    }
    return _size ??= _calculate(sourceWidth, sourceHeight);
  }

  ({int width, int height}) _calculate(int width, int height) {
    final fw = fullscreenWidth ?? 0;
    final fh = fullscreenHeight ?? 0;
    if (fw <= 0 || fh <= 0) return (width: width, height: height);
    final long = math.max(fw, fh);
    final short = math.min(fw, fh);
    final bw = width >= height ? long : short;
    final bh = width >= height ? short : long;
    // 全屏常量作为上限；向下取整使两条边均落在基准内，保持源比例。
    final scale = math.min(1.0, math.min(bw / width, bh / height));
    return (
      width: math.max(1, (width * scale).floor()),
      height: math.max(1, (height * scale).floor()),
    );
  }

  void reset() => _size = null;
}
