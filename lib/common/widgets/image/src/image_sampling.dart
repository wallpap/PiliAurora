import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class ImageDecodeTarget {
  const ImageDecodeTarget._(this.width, this.height, this.fit);

  factory ImageDecodeTarget.forDisplay(
    Size size,
    double devicePixelRatio,
    BoxFit fit,
  ) {
    int bucket(double value) =>
        math.max(1, (value * devicePixelRatio / 16).ceil()) * 16;
    return ImageDecodeTarget._(bucket(size.width), bucket(size.height), fit);
  }

  final int width;
  final int height;
  final BoxFit fit;

  ui.TargetImageSize targetSize(
    int sourceWidth,
    int sourceHeight, {
    int? maximumPixels,
  }) {
    final target = ImageSampling.targetSize(
      sourceSize: Size(sourceWidth.toDouble(), sourceHeight.toDouble()),
      displaySize: Size(width.toDouble(), height.toDouble()),
      devicePixelRatio: 1,
      fit: fit,
    );
    final ratio = maximumPixels == null
        ? 1.0
        : math.min(
            1.0,
            math.sqrt(maximumPixels / (target.width! * target.height!)),
          );
    return ui.TargetImageSize(
      width: math.max(1, (target.width! * ratio).floor()),
      height: math.max(1, (target.height! * ratio).floor()),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ImageDecodeTarget &&
      width == other.width &&
      height == other.height &&
      fit == other.fit;
  @override
  int get hashCode => Object.hash(width, height, fit);
}

abstract final class ImageSampling {
  static ui.TargetImageSize targetSize({
    required ui.Size sourceSize,
    required ui.Size displaySize,
    required double devicePixelRatio,
    required BoxFit fit,
  }) {
    if (sourceSize.isEmpty ||
        displaySize.isEmpty ||
        !sourceSize.width.isFinite ||
        !sourceSize.height.isFinite ||
        !displaySize.width.isFinite ||
        !displaySize.height.isFinite ||
        !devicePixelRatio.isFinite ||
        devicePixelRatio <= 0) {
      throw ArgumentError('图片来源、显示尺寸和像素比例必须有效');
    }
    final fitted = applyBoxFit(fit, sourceSize, displaySize);
    final density = math.min(
      1.0,
      math.max(
            fitted.destination.width / fitted.source.width,
            fitted.destination.height / fitted.source.height,
          ) *
          devicePixelRatio,
    );
    return ui.TargetImageSize(
      width: math.max(1, (sourceSize.width * density).ceil()),
      height: math.max(1, (sourceSize.height * density).ceil()),
    );
  }
}
