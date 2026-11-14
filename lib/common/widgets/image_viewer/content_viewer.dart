import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/common/widgets/gesture/image_horizontal_drag_gesture_recognizer.dart';
import 'package:pili_aurora/common/widgets/image/content_image.dart';
import 'package:pili_aurora/common/widgets/image/src/content_demand.dart';
import 'package:pili_aurora/common/widgets/image_viewer/viewer.dart';

class ContentViewer extends StatefulWidget {
  const ContentViewer({
    super.key,
    required this.image,
    required this.containerSize,
    required this.minScale,
    required this.maxScale,
    required this.doubleTapGestureRecognizer,
    required this.horizontalDragGestureRecognizer,
    this.sourceSize,
    this.placeholder,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onChangePage,
    this.onViewportChanged,
  });

  final ImageProvider image;
  final Size? sourceSize;
  final Size containerSize;
  final double minScale;
  final double maxScale;
  final DoubleTapGestureRecognizer doubleTapGestureRecognizer;
  final ImageHorizontalDragGestureRecognizer horizontalDragGestureRecognizer;
  final WidgetBuilder? placeholder;
  final ValueChanged<ScaleStartDetails>? onDragStart;
  final ValueChanged<ScaleUpdateDetails>? onDragUpdate;
  final ValueChanged<ScaleEndDetails>? onDragEnd;
  final ValueChanged<int>? onChangePage;
  final ValueChanged<ContentViewport>? onViewportChanged;

  @override
  State<ContentViewer> createState() => _ContentViewerState();
}

class _ContentViewerState extends State<ContentViewer> {
  final _viewport = ValueNotifier<ContentViewport?>(null);

  @override
  void dispose() {
    _viewport.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ContentImage(
    image: widget.image,
    sourceSize: widget.sourceSize,
    fit: BoxFit.scaleDown,
    placeholder: widget.placeholder,
    errorBuilder: (_, _, _) => const Center(
      child: Text(
        '图片加载失败',
        style: TextStyle(color: Color(0xffffffff), fontSize: 14),
      ),
    ),
    viewport: _viewport,
    builder: (context, pixels, source) {
      final isLongPic =
          !source.isEmpty &&
          source.height / source.width > Style.imgMaxRatio &&
          source.height > widget.containerSize.height;
      final minimum = isLongPic
          ? math.min(650.0, widget.containerSize.width) /
                widget.containerSize.height *
                source.height /
                source.width
          : widget.minScale;
      return Viewer(
        minScale: minimum,
        maxScale: isLongPic
            ? math.max(widget.maxScale, minimum * 3)
            : widget.maxScale,
        isLongPic: isLongPic,
        containerSize: widget.containerSize,
        childSize: source,
        onDragStart: widget.onDragStart,
        onDragUpdate: widget.onDragUpdate,
        onDragEnd: widget.onDragEnd,
        doubleTapGestureRecognizer: widget.doubleTapGestureRecognizer,
        horizontalDragGestureRecognizer: widget.horizontalDragGestureRecognizer,
        onChangePage: widget.onChangePage,
        onViewportChanged: (viewport) {
          _viewport.value = viewport;
          widget.onViewportChanged?.call(viewport);
        },
        child: pixels,
      );
    },
  );
}
