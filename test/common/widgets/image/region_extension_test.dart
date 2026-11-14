import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/src/image_source_store.dart';
import 'package:pili_aurora/common/widgets/image/src/region_content_session.dart';

class _UnusedBackend implements RegionImageBackend {
  @override
  Future<RegionImageDecoder> open(ImageSourceLease source) =>
      throw UnimplementedError();
}

class _PaintSession extends RegionContentSession {
  _PaintSession(ImageSourceLease source, this.state)
    : super(source: source, backend: _UnusedBackend());
  final RegionContentState state;
  @override
  RegionContentState get value => state;
}

ui.Image pixels(int w, int h, Color color) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(color, BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return picture.toImageSync(w, h);
  } finally {
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final alpha in [0, 64, 128, 255]) {
    testWidgets('base and overlapping details preserve alpha $alpha', (
      tester,
    ) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('region-paint-'),
      ))!;
      final store = (await tester.runAsync(
        () async => ImageSourceStore(Directory('${directory.path}/sources')),
      ))!;
      final file = (await tester.runAsync(
        () => File('${directory.path}/source').writeAsBytes([1]),
      ))!;
      final lease = (await tester.runAsync(() => store.acquire(file)))!;
      final color = Color.fromARGB(alpha, 255, 0, 0);
      final base = pixels(16, 16, color),
          first = pixels(48, 48, color),
          second = pixels(32, 32, color);
      final session = _PaintSession(
        lease,
        RegionContentState(
          sourceSize: const Size(64, 64),
          loading: false,
          images: [
            RegionImage(
              image: base,
              sourceRect: const Rect.fromLTWH(0, 0, 64, 64),
              core: const Rect.fromLTWH(0, 0, 64, 64),
            ),
            RegionImage(
              image: first,
              sourceRect: const Rect.fromLTWH(0, 0, 48, 48),
              core: const Rect.fromLTWH(0, 0, 48, 48),
            ),
            RegionImage(
              image: second,
              sourceRect: const Rect.fromLTWH(16, 16, 32, 32),
              core: const Rect.fromLTWH(16, 16, 32, 32),
            ),
          ],
        ),
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 64,
                height: 64,
                child: ColoredBox(
                  color: const Color(0xff0000ff),
                  child: RegionImageSurface(session: session),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final image = await tester.runAsync(
        () => (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage(),
      );
      final data = (await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      image!.dispose();
      // 三个位置分别覆盖基础层、一次细节和两次重叠细节；每处只应合成一次来源透明度。
      for (final point in [(56, 56), (8, 8), (24, 24)]) {
        final offset = (point.$2 * 64 + point.$1) * 4;
        expect(
          data.getUint8(offset),
          closeTo(alpha, 1),
          reason: 'red at $point',
        );
        expect(
          data.getUint8(offset + 2),
          closeTo(255 - alpha, 1),
          reason: 'blue at $point',
        );
        expect(data.getUint8(offset + 3), 255);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      var drained = false;
      session.drained.then((_) => drained = true);
      session.dispose();
      for (var i = 0; i < 100 && !drained; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
      }
      expect(drained, isTrue);
      base.dispose();
      first.dispose();
      second.dispose();
      await tester.runAsync(() async {
        await store.clear();
        await directory.delete(recursive: true);
      });
    });
  }
}
