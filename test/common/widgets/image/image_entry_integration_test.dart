import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';
import 'package:pili_aurora/common/widgets/image/content_image.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/pages/article/widgets/html_render.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../../support/memory_box.dart';

class _Cache implements BaseCacheManager {
  _Cache(this.file);
  final File file;
  int loads = 0;
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool? withProgress,
  }) async* {
    loads++;
    yield FileInfo(file, FileSource.Cache, DateTime(2100), url);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _png(File file) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const Color(0xff123456), BlendMode.src);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(1600, 400);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  await file.writeAsBytes(bytes!.buffer.asUint8List());
}

Future<RawImage> _loaded(WidgetTester tester) async {
  final finder = find.byWidgetPredicate(
    (widget) => widget is RawImage && widget.image != null,
  );
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    if (finder.evaluate().isNotEmpty) {
      return tester.widget<RawImage>(finder.last);
    }
  }
  fail('real decoder did not publish an image');
}

Widget _host(Widget child) => MaterialApp(
  home: MediaQuery(
    data: const MediaQueryData(devicePixelRatio: 1),
    child: Align(alignment: Alignment.topLeft, child: child),
  ),
);

void main() {
  late Directory directory;
  late File file;
  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>({SettingBoxKey.defaultPicQa: 80});
    GStorage.localCache = MemoryBox<dynamic>();
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('image-entry-');
    file = File('${directory.path}/cover.png');
    await _png(file);
  });
  tearDown(() async {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await directory.delete(recursive: true);
  });

  testWidgets('unknown wide network cover samples enough pixels for cover', (
    tester,
  ) async {
    final cache = _Cache(file);
    await tester.pumpWidget(
      _host(
        NetworkImgLayer(
          src: 'https://example.test/wide-cover.png',
          width: 100,
          height: 100,
          cacheManager: cache,
          fadeInDuration: Duration.zero,
          getPlaceHolder: () => const SizedBox(width: 100, height: 100),
        ),
      ),
    );
    final raw = await _loaded(tester);
    expect(raw.image!.width, greaterThanOrEqualTo(400));
    expect(raw.image!.height, greaterThanOrEqualTo(100));
    expect(raw.image!.width, lessThan(1600));
    expect(cache.loads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'local cover uses actual decoder geometry and honors the same target',
    (tester) async {
      final provider = LocalImageProvider(
        file,
        decodeTarget: ImageDecodeTarget.forDisplay(
          const Size(100, 100),
          1,
          BoxFit.cover,
        ),
      );
      await tester.pumpWidget(
        _host(
          Image(image: provider, width: 100, height: 100, fit: BoxFit.cover),
        ),
      );
      final raw = await _loaded(tester);
      expect(raw.image!.height, greaterThanOrEqualTo(100));
      expect(raw.image!.width, greaterThanOrEqualTo(400));
      expect(raw.image!.width, lessThan(1600));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'external ResizeImage does not replace true source geometry with decoded pixels',
    (tester) async {
      Size? source;
      await tester.pumpWidget(
        _host(
          ContentImage(
            image: ResizeImage(LocalImageProvider(file), width: 80, height: 80),
            sourceSize: const Size(1600, 400),
            width: 200,
            builder: (context, pixels, size) {
              source = size;
              return pixels;
            },
          ),
        ),
      );
      final raw = await _loaded(tester);
      expect(raw.image!.width, lessThanOrEqualTo(80));
      expect(raw.image!.height, lessThanOrEqualTo(80));
      expect(source, const Size(1600, 400));
      expect(tester.getSize(find.byType(ContentImage)), const Size(200, 50));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('failed local keys are evicted so the same file can be retried', (
    tester,
  ) async {
    await tester.runAsync(() => file.writeAsBytes([1, 2, 3]));
    final provider = LocalImageProvider(file);
    var failed = false;
    await tester.pumpWidget(
      _host(
        Image(
          image: provider,
          errorBuilder: (context, error, stack) {
            failed = true;
            return const SizedBox();
          },
        ),
      ),
    );
    for (var attempt = 0; attempt < 50 && !failed; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(failed, isTrue);
    expect(PaintingBinding.instance.imageCache.containsKey(provider), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => _png(file));
    await tester.pumpWidget(_host(Image(image: provider)));
    final raw = await _loaded(tester);
    expect(raw.image!.width, 1600);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('HTML CSS image markers use the application image adapter', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ImageLoadingScope(
          enabled: false,
          child: Builder(
            builder: (context) => htmlRender(
              context: context,
              maxWidth: 300,
              html: '<ul style="list-style-image: url(https://example.test/marker.png)"><li>marker</li></ul>',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CachedImage &&
            widget.imageUrl.startsWith('https://example.test/marker.png'),
      ),
      findsWidgets,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Image && widget.image is NetworkImage,
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
