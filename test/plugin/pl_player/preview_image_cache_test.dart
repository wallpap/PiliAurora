import 'dart:ui' as ui;

import 'package:pili_aurora/plugin/pl_player/utils/preview_image_cache.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ui.Image> _image(int size) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff336699), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  picture.dispose();
  return image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('preview cache limits bytes as well as entry count', () async {
    final cache = PreviewImageCache(maxBytes: 24 * 1024);
    addTearDown(cache.clear);
    // 缩小测试图片，保持与 16MiB 预览图相同的预算比例。
    cache
      ..put('first', await _image(64))
      ..put('second', await _image(64))
      ..put('third', await _image(64));
    final old = cache.acquire('first');
    addTearDown(() => old?.dispose());
    expect(old, isNull);
    expect(cache.sizeBytes, 64 * 64 * 4);
  });

  test(
    'eviction releases the cache handle but not the displayed image',
    () async {
      final cache = PreviewImageCache(maxEntries: 2, maxBytes: 1024);
      addTearDown(cache.clear);
      cache.put('first', await _image(8));
      final displayed = cache.acquire('first')!;
      addTearDown(displayed.dispose);
      cache
        ..put('second', await _image(8))
        ..put('third', await _image(8));
      expect(cache.acquire('first'), isNull);
      expect(displayed.debugDisposed, isFalse);
      expect(await displayed.toByteData(), isNotNull);
    },
  );

  test(
    'oversized images are displayed without displacing useful cached previews',
    () async {
      final cache = PreviewImageCache(maxBytes: 1024);
      addTearDown(cache.clear);
      cache.put('small', await _image(8));
      final large = await _image(32);
      final displayed = large.clone();
      addTearDown(displayed.dispose);
      cache.put('large', large);
      expect(large.debugDisposed, isTrue);
      expect(cache.acquire('large'), isNull);
      expect(cache.sizeBytes, 256);
      expect(await displayed.toByteData(), isNotNull);
    },
  );

  test(
    'reads update recency and clearing advances the request generation',
    () async {
      final cache = PreviewImageCache(maxEntries: 2);
      addTearDown(cache.clear);
      cache
        ..put('first', await _image(8))
        ..put('second', await _image(8));
      cache.acquire('first')!.dispose();
      cache.put('third', await _image(8));
      expect(cache.acquire('second'), isNull);
      final generation = cache.generation;
      cache.clear();
      expect(cache.generation, generation + 1);
      expect(cache.sizeBytes, 0);
      expect(cache.acquire('first'), isNull);
    },
  );
}
