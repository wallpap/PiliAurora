import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:pili_aurora/common/widgets/image/cached_image.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _FileCache implements BaseCacheManager {
  _FileCache(this.file);

  final File file;
  int loads = 0;
  Completer<void>? gate;
  Object? failure;
  Completer<void>? refresh;

  @override
  Future<File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async {
    loads++;
    await gate?.future;
    if (failure case final error?) throw error;
    return file;
  }

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool? withProgress,
  }) async* {
    yield FileInfo(
      await getSingleFile(url),
      FileSource.Cache,
      DateTime(2100),
      url,
    );
    await refresh?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Frame implements ui.FrameInfo {
  _Frame(this.image);

  @override
  final ui.Image image;

  @override
  Duration get duration => const Duration(milliseconds: 100);
}

class _TrackedCodec implements ui.Codec {
  _TrackedCodec(this.image, {this.frameCount = 1});

  final ui.Image image;
  bool disposed = false;
  int decodedFrames = 0;

  @override
  final int frameCount;

  @override
  int get repetitionCount => 0;

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    decodedFrames++;
    return _Frame(image.clone());
  }

  @override
  void dispose() {
    disposed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _FileCache manager;
  late ui.Image source;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pili-image-lifecycle-');
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff336699), ui.BlendMode.src);
    final picture = recorder.endRecording();
    source = await picture.toImage(2, 2);
    picture.dispose();
    final bytes = await source.toByteData(format: ui.ImageByteFormat.png);
    final file = await File('${directory.path}/image.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    manager = _FileCache(file);
  });

  tearDownAll(() async {
    source.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'removing an image releases its native codec without waiting for GC',
    () async {
      final provider = CachedImageProvider(
        'https://example.test/image.png',
        cacheManager: manager,
      );
      final codec = _TrackedCodec(source);
      final completer = provider.loadImage(provider, (
        buffer, {
        getTargetSize,
      }) async {
        buffer.dispose();
        return codec;
      });
      final loaded = Completer<void>();
      final listener = ImageStreamListener((info, _) {
        info.dispose();
        if (!loaded.isCompleted) loaded.complete();
      }, onError: loaded.completeError);
      completer.addListener(listener);
      await loaded.future;
      completer.removeListener(listener);
      await Future<void>.delayed(Duration.zero);

      expect(
        codec.disposed,
        isTrue,
        reason: '刷新或滚出列表后，原生解码器应立即释放，不能依赖 Dart GC。',
      );
    },
  );

  test('a codec completing after its image was removed is released', () async {
    final provider = CachedImageProvider(
      'https://example.test/late.png',
      cacheManager: manager,
    );
    final decoding = Completer<void>();
    final ready = Completer<ui.Codec>();
    final codec = _TrackedCodec(source);
    final completer = provider.loadImage(provider, (buffer, {getTargetSize}) {
      buffer.dispose();
      decoding.complete();
      return ready.future;
    });
    final listener = ImageStreamListener((info, _) => info.dispose());
    completer.addListener(listener);
    await decoding.future;
    completer.removeListener(listener);
    ready.complete(codec);
    await Future<void>.delayed(Duration.zero);

    expect(codec.disposed, isTrue);
    expect(codec.decodedFrames, 0);
  });

  test(
    'a cached animation stays reusable until its final cache handle leaves',
    () async {
      final provider = CachedImageProvider(
        'https://example.test/animation.gif',
        cacheManager: manager,
      );
      final decoding = Completer<void>();
      final codec = _TrackedCodec(source, frameCount: 2);
      final completer = provider.loadImage(provider, (
        buffer, {
        getTargetSize,
      }) async {
        buffer.dispose();
        decoding.complete();
        return codec;
      });
      final listener = ImageStreamListener((info, _) => info.dispose());
      completer.addListener(listener);
      final handle = completer.keepAlive();
      await decoding.future;
      await Future<void>.delayed(Duration.zero);
      completer.removeListener(listener);
      expect(codec.disposed, isFalse);

      completer.addListener(listener);
      expect(codec.disposed, isFalse);
      completer.removeListener(listener);
      handle.dispose();
      expect(codec.disposed, isTrue);
    },
  );

  test('long thumbnails stay within their pixel budget and the viewer keeps full resolution', () async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff336699), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final longImage = await picture.toImage(400, 16000);
    picture.dispose();
    final bytes = await longImage.toByteData(format: ui.ImageByteFormat.png);
    longImage.dispose();
    final file = await File('${directory.path}/long.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    final cache = _FileCache(file);

    Future<int> pixels(ImageProvider provider) async {
      final stream = provider.resolve(ImageConfiguration.empty);
      final result = Completer<int>();
      final listener = ImageStreamListener((info, _) {
        result.complete(info.image.width * info.image.height);
        info.dispose();
      }, onError: result.completeError);
      stream.addListener(listener);
      try {
        return await result.future;
      } finally {
        stream.removeListener(listener);
        await provider.evict();
      }
    }

    final legacyPixels = await pixels(
      ResizeImage(
        CachedNetworkImageProvider(
          'https://example.test/long.png',
          cacheManager: cache,
        ),
        width: 300,
      ),
    );
    final thumbnailPixels = await pixels(
      CachedImageProvider(
        'https://example.test/long.png',
        cacheManager: cache,
        width: 300,
        maxDecodePixels: 1 << 20,
      ),
    );
    final viewerPixels = await pixels(
      CachedImageProvider('https://example.test/long.png', cacheManager: cache),
    );

    expect(legacyPixels, 300 * 12000);
    expect(thumbnailPixels, lessThanOrEqualTo(1 << 20));
    expect(viewerPixels, 400 * 16000);
  });

  test('simultaneous sizes share one pending file request', () async {
    final cache = _FileCache(manager.file)..gate = Completer<void>();
    final results = <Future<void>>[];
    for (final width in [100, 200, 300]) {
      final provider = CachedImageProvider(
        'https://example.test/shared.png',
        cacheManager: cache,
        width: width,
      );
      final loaded = Completer<void>();
      final completer = provider.loadImage(provider, (
        buffer, {
        getTargetSize,
      }) async {
        buffer.dispose();
        return _TrackedCodec(source);
      });
      late final ImageStreamListener listener;
      listener = ImageStreamListener((info, _) {
        info.dispose();
        completer.removeListener(listener);
        loaded.complete();
      }, onError: loaded.completeError);
      completer.addListener(listener);
      results.add(loaded.future);
    }
    cache.gate!.complete();
    await Future.wait(results);
    expect(cache.loads, 1);
  });

  test('failed file requests can be retried', () async {
    final cache = _FileCache(manager.file)
      ..failure = const FileSystemException('test failure');
    final provider = CachedImageProvider(
      'https://example.test/retry.png',
      cacheManager: cache,
    );

    Future<void> load() async {
      final completer = provider.loadImage(provider, (
        buffer, {
        getTargetSize,
      }) async {
        buffer.dispose();
        return _TrackedCodec(source);
      });
      final loaded = Completer<void>();
      final listener = ImageStreamListener((info, _) {
        info.dispose();
        loaded.complete();
      }, onError: loaded.completeError);
      completer.addListener(listener);
      try {
        await loaded.future;
      } finally {
        completer.removeListener(listener);
      }
    }

    await expectLater(load(), throwsA(isA<FileSystemException>()));
    cache.failure = null;
    await load();
    expect(cache.loads, 2);
  });

  test('a cached file is usable while refresh is pending or fails', () async {
    final cache = _FileCache(manager.file)..refresh = Completer<void>();
    final provider = CachedImageProvider(
      'https://example.test/stale.png',
      cacheManager: cache,
    );
    final completer = provider.loadImage(provider, (
      buffer, {
      getTargetSize,
    }) async {
      buffer.dispose();
      return _TrackedCodec(source);
    });
    final loaded = Completer<void>();
    final listener = ImageStreamListener((info, _) {
      info.dispose();
      loaded.complete();
    }, onError: loaded.completeError);
    completer.addListener(listener);
    await loaded.future;
    expect(cache.refresh!.isCompleted, isFalse);
    cache.refresh!.completeError(const FileSystemException('offline'));
    await Future<void>.delayed(Duration.zero);
    completer.removeListener(listener);
  });

  testWidgets('cached image paints through loading, URL changes and removal', (
    tester,
  ) async {
    final cache = _FileCache(manager.file);
    Future<void> show(String url) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: CachedImage(
                imageUrl: url,
                cacheManager: cache,
                width: 100,
                height: 80,
                fit: BoxFit.cover,
                placeholder: (_, _) =>
                    const SizedBox(key: ValueKey('placeholder')),
              ),
            ),
          ),
        );
        final provider = tester.widget<Image>(find.byType(Image)).image;
        final stream = provider.resolve(ImageConfiguration.empty);
        final loaded = Completer<void>();
        final listener = ImageStreamListener((info, _) {
          info.dispose();
          loaded.complete();
        }, onError: loaded.completeError);
        stream.addListener(listener);
        try {
          await loaded.future;
        } finally {
          stream.removeListener(listener);
        }
      });
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('placeholder')), findsNothing);
      expect(tester.getSize(find.byType(RawImage)), const Size(100, 80));
      expect(tester.takeException(), isNull);
    }

    await show('https://example.test/widget-first.png');
    await show('https://example.test/widget-second.png');
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache.clear();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached image applies the thumbnail pixel budget by default', (
    tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CachedImage(
          imageUrl: 'https://example.test/unbounded.png',
          cacheManager: manager,
        ),
      ),
    );

    final provider = tester.widget<Image>(find.byType(Image)).image;
    expect((provider as CachedImageProvider).maxDecodePixels, 1 << 20);
  });
}
