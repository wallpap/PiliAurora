import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/progress_bar/segment_progress_bar.dart';

class _TestPaintingContext extends PaintingContext {
  _TestPaintingContext(super.containerLayer, super.estimatedBounds);

  void finish() => stopRecordingIfNeeded();
}

Future<List<int>> _pixels(RenderViewPointProgressBar bar, double width) async {
  bar.layout(BoxConstraints.tightFor(width: width, height: 15));
  final layer = OffsetLayer();
  final context = _TestPaintingContext(layer, Rect.fromLTWH(0, 0, width, 20));
  bar.paint(context, Offset.zero);
  context.finish();
  final image = await layer.toImage(Rect.fromLTWH(0, 0, width, 20));
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer
        .asUint8List();
  } finally {
    image.dispose();
    layer.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cached chapter text renders consistently across paints and resize',
    () async {
      final segments = [
        const ViewPointSegment(end: 0.5, title: '第一章'),
        const ViewPointSegment(end: 1, title: '比较长的第二章节标题'),
      ];
      final bar = RenderViewPointProgressBar(height: 3.5, segments: segments);
      addTearDown(bar.dispose);
      expect(await _pixels(bar, 300), await _pixels(bar, 300));
      final fresh = RenderViewPointProgressBar(height: 3.5, segments: segments);
      addTearDown(fresh.dispose);
      expect(await _pixels(bar, 180), await _pixels(fresh, 180));
    },
  );

  test('changing chapter titles paints the new text', () async {
    final bar = RenderViewPointProgressBar(
      height: 3.5,
      segments: [
        const ViewPointSegment(end: 1, title: '旧章节'),
      ],
    );
    addTearDown(bar.dispose);
    final old = await _pixels(bar, 300);
    bar.segments = [const ViewPointSegment(end: 1, title: '全新的章节标题')];
    final current = await _pixels(bar, 300);
    expect(current, isNot(equals(old)));
    final fresh = RenderViewPointProgressBar(
      height: 3.5,
      segments: bar.segments,
    );
    addTearDown(fresh.dispose);
    expect(current, await _pixels(fresh, 300));
  });
}
