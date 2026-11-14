import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/gesture/image_horizontal_drag_gesture_recognizer.dart';
import 'package:pili_aurora/common/widgets/image/src/content_demand.dart';
import 'package:pili_aurora/common/widgets/image_viewer/content_viewer.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../../support/memory_box.dart';

class _Stream extends ImageStreamCompleter {
  void publish(int dimension) {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xff123456), BlendMode.src);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(dimension, dimension);
    picture.dispose();
    setImage(ImageInfo(image: image));
  }
}

class _Provider extends ImageProvider<Object> {
  final key = Object();
  final stream = _Stream();
  @override
  Future<Object> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(key);
  @override
  ImageStreamCompleter loadImage(Object key, ImageDecoderCallback decode) =>
      stream;
}

void main() {
  setUpAll(() => GStorage.setting = MemoryBox<dynamic>());
  tearDown(
    () => PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages(),
  );

  testWidgets('failed image shows a message in the viewer', (tester) async {
    final provider = _Provider();
    final doubleTap = DoubleTapGestureRecognizer();
    final horizontal = ImageHorizontalDragGestureRecognizer();
    addTearDown(doubleTap.dispose);
    addTearDown(horizontal.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(),
          child: ContentViewer(
            image: provider,
            containerSize: const Size(400, 400),
            minScale: 1,
            maxScale: 8,
            doubleTapGestureRecognizer: doubleTap,
            horizontalDragGestureRecognizer: horizontal,
          ),
        ),
      ),
    );
    provider.stream.reportError(
      exception: StateError('fixture decode failed'),
    );
    await tester.pump();
    expect(find.text('图片加载失败'), findsOneWidget);
    expect(tester.getSize(find.text('图片加载失败')).isEmpty, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'sampling changes retain the viewport and resize retains its focus and density',
    (tester) async {
      final provider = _Provider();
      final doubleTap = DoubleTapGestureRecognizer();
      final horizontal = ImageHorizontalDragGestureRecognizer();
      final demands = <ContentViewport>[];
      addTearDown(doubleTap.dispose);
      addTearDown(horizontal.dispose);
      Widget host(Size size) => Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 2),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: size,
              child: ContentViewer(
                image: provider,
                sourceSize: const Size(1600, 1600),
                containerSize: size,
                minScale: 1,
                maxScale: 8,
                doubleTapGestureRecognizer: doubleTap,
                horizontalDragGestureRecognizer: horizontal,
                onViewportChanged: demands.add,
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(host(const Size(400, 400)));
      provider.stream.publish(100);
      await tester.pump();
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(200, 200),
          scrollDelta: Offset(0, -140),
        ),
      );
      await tester.pump();
      final zoomed = demands.last;
      expect(zoomed.sourceRect.width, lessThan(1600));
      provider.stream.publish(400);
      await tester.pump();
      expect(demands.last.sourceRect, zoomed.sourceRect);
      expect(demands.last.physicalScale, zoomed.physicalScale);
      await tester.pumpWidget(host(const Size(450, 350)));
      expect(
        (demands.last.sourceRect.center - zoomed.sourceRect.center).distance,
        lessThan(.001),
      );
      expect(demands.last.physicalScale, closeTo(zoomed.physicalScale, .001));
      expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 400);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wheel pinch pan double tap and fling publish source viewport changes',
    (tester) async {
      final provider = _Provider();
      final doubleTap = DoubleTapGestureRecognizer()..onDoubleTap = () {};
      final horizontal = ImageHorizontalDragGestureRecognizer();
      final demands = <ContentViewport>[];
      addTearDown(doubleTap.dispose);
      addTearDown(horizontal.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(devicePixelRatio: 1),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                height: 400,
                child: Listener(
                  onPointerDown: doubleTap.addPointer,
                  child: ContentViewer(
                    image: provider,
                    sourceSize: const Size(1600, 1600),
                    containerSize: const Size(400, 400),
                    minScale: 1,
                    maxScale: 8,
                    doubleTapGestureRecognizer: doubleTap,
                    horizontalDragGestureRecognizer: horizontal,
                    onViewportChanged: demands.add,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      provider.stream.publish(200);
      await tester.pump();
      final initial = demands.last;
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(200, 200),
          scrollDelta: Offset(0, -120),
        ),
      );
      await tester.pump();
      expect(demands.last.physicalScale, greaterThan(initial.physicalScale));
      final beforePinch = demands.last;
      final pinch = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await pinch.panZoomStart(const Offset(200, 200));
      await pinch.panZoomUpdate(const Offset(200, 200), scale: 1.1);
      await pinch.panZoomUpdate(const Offset(200, 200), scale: 1.6);
      await tester.pump();
      expect(
        demands.last.physicalScale,
        greaterThan(beforePinch.physicalScale),
      );
      await pinch.panZoomEnd();
      final beforePan = demands.last;
      final pan = await tester.createGesture(kind: PointerDeviceKind.trackpad);
      await pan.panZoomStart(const Offset(200, 200));
      await pan.panZoomUpdate(const Offset(200, 200), pan: const Offset(0, 30));
      await pan.panZoomUpdate(const Offset(200, 200), pan: const Offset(0, 80));
      await tester.pump();
      expect(
        demands.last.sourceRect.center,
        isNot(beforePan.sourceRect.center),
      );
      await pan.panZoomEnd();
      await tester.tapAt(const Offset(200, 200));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(const Offset(200, 200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(demands.last.physicalScale, closeTo(initial.physicalScale, .001));
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(200, 200),
          scrollDelta: Offset(0, -220),
        ),
      );
      await tester.pump();
      await tester.fling(
        find.byType(ContentViewer),
        const Offset(0, -100),
        800,
      );
      await tester.pump();
      final beforeFling = demands.last.sourceRect.center;
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pump(const Duration(milliseconds: 32));
      expect(demands.last.sourceRect.center, isNot(beforeFling));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
    },
  );
}
