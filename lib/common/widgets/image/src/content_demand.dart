import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

@immutable
class ContentViewport {
  const ContentViewport(this.sourceRect, this.physicalScale);
  final Rect sourceRect;
  final double physicalScale;
}

@immutable
class ContentDemand {
  const ContentDemand({
    required this.viewport,
    this.load = true,
    this.animate = true,
  });
  final ContentViewport viewport;
  final bool load;
  final bool animate;
}
