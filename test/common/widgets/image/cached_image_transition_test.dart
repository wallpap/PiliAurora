import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';

Widget _imageFrame({
  String url = 'https://example.test/image.png',
  int? frame = 0,
  bool synchronouslyLoaded = false,
  Duration fadeIn = const Duration(milliseconds: 120),
  Duration fadeOut = const Duration(milliseconds: 120),
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    child: RepaintBoundary(
      key: const ValueKey('image-boundary'),
      child: SizedBox(
        width: 100,
        height: 80,
        child: Builder(
          builder: (context) {
            final image = CachedImage(
              imageUrl: url,
              width: 100,
              height: 80,
              fadeInDuration: fadeIn,
              fadeOutDuration: fadeOut,
              placeholder: (_, _) => const ColoredBox(
                color: Color(0xffff0000),
                key: ValueKey('placeholder'),
              ),
            ).build(context) as Image;
            return image.frameBuilder!(
              context,
              const SizedBox.expand(
                key: ValueKey('image'),
                child: ColoredBox(color: Color(0x00000000)),
              ),
              frame,
              synchronouslyLoaded,
            );
          },
        ),
      ),
    ),
  ),
);

Future<int> _placeholderAlpha(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('image-boundary')),
  );
  final image = boundary.toImageSync();
  try {
    final bytes = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    return bytes!.getUint8(3);
  } finally {
    image.dispose();
  }
}

void main() {
  testWidgets('a cached replacement does not inherit the previous fade', (
    tester,
  ) async {
    await tester.pumpWidget(_imageFrame());
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.byType(FadeTransition), findsWidgets);

    await tester.pumpWidget(
      _imageFrame(
        url: 'https://example.test/cached.png',
        synchronouslyLoaded: true,
      ),
    );

    expect(find.byType(FadeTransition), findsNothing);
    expect(find.byKey(const ValueKey('placeholder')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('synchronous delivery skips a fade even when ready stays true', (
    tester,
  ) async {
    await tester.pumpWidget(_imageFrame());
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpWidget(_imageFrame(synchronouslyLoaded: true));

    expect(find.byType(FadeTransition), findsNothing);
    expect(find.byKey(const ValueKey('placeholder')), findsNothing);
  });

  testWidgets('the placeholder fades behind transparent image pixels', (
    tester,
  ) async {
    await tester.pumpWidget(_imageFrame());
    await tester.pump(const Duration(milliseconds: 60));

    expect(await _placeholderAlpha(tester), closeTo(128, 2));

    await tester.pump(const Duration(milliseconds: 60));
    expect(await _placeholderAlpha(tester), 0);
    await tester.pumpAndSettle();
    expect(find.byType(FadeTransition), findsNothing);
    expect(find.byType(Stack), findsNothing);
  });

  testWidgets('fade out duration remains independent from fade in duration', (
    tester,
  ) async {
    await tester.pumpWidget(
      _imageFrame(fadeOut: const Duration(milliseconds: 240)),
    );
    await tester.pump(const Duration(milliseconds: 120));

    expect(await _placeholderAlpha(tester), closeTo(128, 2));

    await tester.pump(const Duration(milliseconds: 120));
    await tester.pumpAndSettle();
    expect(find.byType(FadeTransition), findsNothing);
    expect(find.byKey(const ValueKey('placeholder')), findsNothing);
  });

  testWidgets('zero durations take effect without a ready transition', (
    tester,
  ) async {
    await tester.pumpWidget(_imageFrame());
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpWidget(
      _imageFrame(fadeIn: Duration.zero, fadeOut: Duration.zero),
    );

    expect(find.byType(FadeTransition), findsNothing);
    expect(find.byKey(const ValueKey('placeholder')), findsNothing);
  });

  testWidgets(
    'a replacement starts a fresh fade and removal stops its ticker',
    (
      tester,
    ) async {
      await tester.pumpWidget(_imageFrame());
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpWidget(
        _imageFrame(url: 'https://example.test/replacement.png'),
      );

      expect(await _placeholderAlpha(tester), 255);
      await tester.pump(const Duration(milliseconds: 60));
      expect(await _placeholderAlpha(tester), closeTo(128, 2));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 120));
      expect(tester.takeException(), isNull);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}
