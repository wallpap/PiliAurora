import '../../video_output_size_policy.dart';

/// 输出上限来自设备显示分辨率，不来自当前 viewport。一个媒体只确定一次输出。
/// 上限沿长/短边与源对齐；超过上限的源等比缩小，较小的源保持原尺寸。
class AndroidFixedSurfaceSize {
  AndroidFixedSurfaceSize({this.limitWidth, this.limitHeight, this.readLimit});
  final int? limitWidth;
  final int? limitHeight;
  final VideoOutputSize? Function()? readLimit;
  VideoOutputSize? _resolvedLimit;
  VideoOutputSize? get resolvedLimit => _resolvedLimit;
  ({int width, int height})? _size;
  ({int width, int height})? get size => _size;

  ({int width, int height}) resolve(int sourceWidth, int sourceHeight) {
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      throw ArgumentError('Invalid source size: ${sourceWidth}x$sourceHeight');
    }
    return _size ??= _calculate(sourceWidth, sourceHeight);
  }

  ({int width, int height}) _calculate(int width, int height) {
    _resolvedLimit =
        readLimit?.call() ??
        switch ((limitWidth, limitHeight)) {
          (final width?, final height?) => (width: width, height: height),
          _ => null,
        };
    return VideoOutputSizePolicy.fitWithinLimit(
          source: (width: width, height: height),
          limit: _resolvedLimit,
        ) ??
        (width: width, height: height);
  }

  void reset() {
    _size = null;
    _resolvedLimit = null;
  }
}
