import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';
import 'package:pili_aurora/common/widgets/image/content_image.dart';

class _Stream extends ImageStreamCompleter {}

class _Provider extends ImageProvider<Object> {
  final key = Object();
  final stream = _Stream();
  int loads = 0;
  @override
  Future<Object> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(key);
  @override
  ImageStreamCompleter loadImage(Object key, ImageDecoderCallback decode) {
    loads++;
    return stream;
  }
}

ui.Image _image(int width, int height) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(width, height);
  picture.dispose();
  return image;
}

Widget _host(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: const MediaQueryData(devicePixelRatio: 2),
    child: Align(alignment: Alignment.topLeft, child: child),
  ),
);

void main() {
  tearDown(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  testWidgets('long content keeps source geometry across decoded resolutions', (
    tester,
  ) async {
    final provider = _Provider();
    final source = _image(20, 400);
    final detail = _image(40, 800);
    final scroll = ScrollController();
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 200,
          height: 300,
          child: SingleChildScrollView(
            controller: scroll,
            child: ContentImage(
              image: provider,
              sourceSize: const Size(400, 8000),
              width: 200,
              key: const ValueKey('content'),
            ),
          ),
        ),
      ),
    );
    provider.stream.setImage(ImageInfo(image: source));
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('content'))),
      const Size(200, 4000),
    );
    scroll.jumpTo(1200);
    await tester.pump();
    provider.stream.setImage(ImageInfo(image: detail));
    await tester.pump();
    expect(
      tester.getSize(find.byKey(const ValueKey('content'))),
      const Size(200, 4000),
    );
    expect(scroll.offset, 1200);
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
  });

  testWidgets('static export may load while TickerMode disables animation', (
    tester,
  ) async {
    final provider = _Provider();
    await tester.pumpWidget(
      _host(
        ImageLoadingScope(
          enabled: true,
          child: TickerMode(
            enabled: false,
            child: ContentImage(
              image: provider,
              sourceSize: const Size(16, 8),
              width: 160,
              height: 80,
            ),
          ),
        ),
      ),
    );
    expect(provider.loads, 1);
    provider.stream.setImage(ImageInfo(image: _image(16, 8)));
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is RawImage && widget.image != null,
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'disabled loading creates no stream and preserves declared layout',
    (tester) async {
      final provider = _Provider();
      await tester.pumpWidget(
        _host(
          ImageLoadingScope(
            enabled: false,
            child: ContentImage(
              image: provider,
              sourceSize: const Size(400, 8000),
              width: 200,
              height: 4000,
              key: const ValueKey('content'),
            ),
          ),
        ),
      );
      expect(provider.loads, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'late frames from a replaced source do not replace current content',
    (tester) async {
      final first = _Provider();
      final second = _Provider();
      Widget content(_Provider provider) => _host(
        ContentImage(
          image: provider,
          sourceSize: const Size(16, 8),
          width: 160,
          height: 80,
        ),
      );
      await tester.pumpWidget(content(first));
      await tester.pumpWidget(content(second));
      second.stream.setImage(ImageInfo(image: _image(16, 8)));
      await tester.pump();
      first.stream.setImage(ImageInfo(image: _image(32, 16)));
      await tester.pump();
      final raw = tester.widget<RawImage>(
        find.byWidgetPredicate(
          (widget) => widget is RawImage && widget.image != null,
        ),
      );
      expect(raw.image!.width, 16);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
