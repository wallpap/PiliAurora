import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';

class _Binding extends AutomatedTestWidgetsFlutterBinding {
  @override
  ImageCache createImageCache() => CachedImageCache();
}

class _FileCache implements BaseCacheManager {
  _FileCache(this.file);
  final File file;
  Completer<void>? gate;
  Object? failure;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool? withProgress,
  }) async* {
    await gate?.future;
    if (failure case final error?) throw error;
    yield FileInfo(file, FileSource.Cache, DateTime(2100), url);
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

class _Codec implements ui.Codec {
  _Codec(this.source, this.frameCount);
  final ui.Image source;
  final images = <ui.Image>[];
  Completer<void>? afterFirstFrame;
  Object? failure;
  int requests = 0;
  int disposals = 0;
  @override
  final int frameCount;
  @override
  int get repetitionCount => -1;
  @override
  Future<ui.FrameInfo> getNextFrame() async {
    if (failure case final error?) throw error;
    if (++requests > 1) await afterFirstFrame?.future;
    final image = source.clone();
    images.add(image);
    return _Frame(image);
  }

  @override
  void dispose() => disposals++;
}

class _Provider extends CachedImageProvider {
  _Provider(super.url, this.source, _FileCache cache, {this.frames = 2})
    : super(cacheManager: cache);
  final ui.Image source;
  final int frames;
  final codecs = <_Codec>[];
  Completer<void>? afterFirstFrame;
  Object? frameFailure;

  @override
  ImageStreamCompleter loadImage(
    CachedImageProvider key,
    ImageDecoderCallback decode,
  ) => super.loadImage(key, (buffer, {getTargetSize}) async {
    buffer.dispose();
    final codec = _Codec(source, frames)
      ..afterFirstFrame = afterFirstFrame
      ..failure = frameFailure;
    codecs.add(codec);
    return codec;
  });
}

class _NativeCodec implements ui.Codec {
  _NativeCodec(this.delegate);
  final ui.Codec delegate;
  int disposals = 0;
  @override
  int get frameCount => delegate.frameCount;
  @override
  int get repetitionCount => delegate.repetitionCount;
  @override
  Future<ui.FrameInfo> getNextFrame() => delegate.getNextFrame();
  @override
  void dispose() {
    disposals++;
    delegate.dispose();
  }
}

class _NativeProvider extends CachedImageProvider {
  _NativeProvider(_FileCache files)
    : super('https://example.test/native.webp', cacheManager: files);
  final codecs = <_NativeCodec>[];

  @override
  ImageStreamCompleter loadImage(
    CachedImageProvider key,
    ImageDecoderCallback decode,
  ) => super.loadImage(key, (buffer, {getTargetSize}) async {
    final codec = _NativeCodec(
      await decode(buffer, getTargetSize: getTargetSize),
    );
    codecs.add(codec);
    return codec;
  });
}

Future<void> _tick(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 5)),
  );
  tester.binding.scheduleFrame();
  await tester.pump(const Duration(milliseconds: 16));
}

Future<void> _until(
  WidgetTester tester,
  bool Function() done,
) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await _tick(tester);
  }
  expect(done(), isTrue);
}

void main() {
  _Binding();
  late Directory directory;
  late File file;
  late ui.Image source;
  late _FileCache files;
  final cache = PaintingBinding.instance.imageCache;
  final listener = ImageStreamListener((info, _) => info.dispose());

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pili-cache-lifecycle-');
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
    final picture = recorder.endRecording();
    source = await picture.toImage(2, 2);
    picture.dispose();
    final bytes = await source.toByteData(format: ui.ImageByteFormat.png);
    file = await File('${directory.path}/image.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
  });
  setUp(() => files = _FileCache(file));
  tearDownAll(() async {
    source.dispose();
    await directory.delete(recursive: true);
  });

  testWidgets('late pending animations release codecs without clearing cache', (
    tester,
  ) async {
    files.gate = Completer<void>();
    final providers = [
      for (var i = 0; i < 12; i++)
        _Provider('https://example.test/pending-$i.gif', source, files),
    ];
    for (final provider in providers) {
      provider.resolve(ImageConfiguration.empty)
        ..addListener(listener)
        ..removeListener(listener);
    }
    expect(cache.pendingImageCount, 12);
    expect(providers.every((p) => p.codecs.isEmpty), isTrue);
    files.gate!.complete();
    try {
      await _until(tester, () => cache.pendingImageCount == 0);
      await _tick(tester);
      expect(cache.liveImageCount, 0);
      expect(providers.every((p) => p.codecs.single.disposals == 1), isTrue);
      expect(cache.currentSize, 0);
    } finally {
      cache
        ..clear()
        ..clearLiveImages();
      await _tick(tester);
    }
  });

  testWidgets('shared animation stays alive until its last viewer leaves', (
    tester,
  ) async {
    final provider = _Provider(
      'https://example.test/shared.gif',
      source,
      files,
    );
    final first = provider.resolve(ImageConfiguration.empty)
      ..addListener(listener);
    final second = provider.resolve(ImageConfiguration.empty)
      ..addListener(listener);
    try {
      await _until(tester, () => !cache.statusForKey(provider).pending);
      first.removeListener(listener);
      await _tick(tester);
      expect(provider.codecs.single.disposals, 0);
      expect(cache.statusForKey(provider).live, isTrue);
      second.removeListener(listener);
      await _tick(tester);
      expect(provider.codecs.single.disposals, 1);
      expect(cache.statusForKey(provider).untracked, isTrue);
      final restored = provider.resolve(ImageConfiguration.empty)
        ..addListener(listener);
      await _until(tester, () => provider.codecs.length == 2);
      restored.removeListener(listener);
    } finally {
      cache
        ..clear()
        ..clearLiveImages();
      await _tick(tester);
    }
  });

  testWidgets('static images retain their cached frame after the view leaves', (
    tester,
  ) async {
    final provider = _Provider(
      'https://example.test/static.png',
      source,
      files,
      frames: 1,
    );
    final stream = provider.resolve(ImageConfiguration.empty)
      ..addListener(listener);
    try {
      await _until(tester, () => !cache.statusForKey(provider).pending);
      stream.removeListener(listener);
      await _tick(tester);
      expect(provider.codecs.single.disposals, 1);
      expect(cache.statusForKey(provider).keepAlive, isTrue);
      final restored = provider.resolve(ImageConfiguration.empty)
        ..addListener(listener);
      expect(identical(restored.completer, stream.completer), isTrue);
      expect(provider.codecs, hasLength(1));
      restored.removeListener(listener);
    } finally {
      cache
        ..clear()
        ..clearLiveImages();
      await _tick(tester);
    }
  });

  testWidgets(
    'resized animation evicts its outer cache key and preserves explicit handles',
    (
      tester,
    ) async {
      final provider = _Provider(
        'https://example.test/resized.gif',
        source,
        files,
      );
      final resized = ResizeImage(provider, width: 2);
      final key = await resized.obtainKey(ImageConfiguration.empty);
      final stream = resized.resolve(ImageConfiguration.empty)
        ..addListener(listener);
      final handle = stream.completer!.keepAlive();
      try {
        await _until(tester, () => !cache.statusForKey(key).pending);
        stream.removeListener(listener);
        await _tick(tester);
        expect(cache.statusForKey(key).untracked, isTrue);
        expect(provider.codecs.single.disposals, 0);
        stream.addListener(listener);
        await _tick(tester);
        expect(provider.codecs.single.disposals, 0);
        stream.removeListener(listener);
      } finally {
        handle.dispose();
        cache
          ..clear()
          ..clearLiveImages();
        await _tick(tester);
      }
      expect(provider.codecs.single.disposals, 1);
    },
  );

  testWidgets(
    'cache eviction waits for an in-flight frame before native disposal',
    (
      tester,
    ) async {
      final gate = Completer<void>();
      final provider = _Provider(
        'https://example.test/inflight.gif',
        source,
        files,
      )..afterFirstFrame = gate;
      final stream = provider.resolve(ImageConfiguration.empty)
        ..addListener(listener);
      await _until(
        tester,
        () =>
            provider.codecs.isNotEmpty && provider.codecs.single.requests == 2,
      );
      final codec = provider.codecs.single;
      stream.removeListener(listener);
      await _tick(tester);
      expect(cache.statusForKey(provider).untracked, isTrue);
      expect(codec.disposals, 0);
      gate.complete();
      await _until(tester, () => codec.disposals == 1);
      expect(codec.images.every((image) => image.debugDisposed), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an evicted old animation cannot evict a replacement cache entry',
    (
      tester,
    ) async {
      const url = 'https://example.test/replaced.gif';
      final previous = _Provider(url, source, files);
      final oldStream = previous.resolve(ImageConfiguration.empty)
        ..addListener(listener);
      await _until(tester, () => !cache.statusForKey(previous).pending);
      cache.evict(previous);
      await _tick(tester);
      final replacement = _Provider(url, source, files, frames: 1);
      final newStream = replacement.resolve(ImageConfiguration.empty)
        ..addListener(listener);
      try {
        await _until(tester, () => !cache.statusForKey(replacement).pending);
        newStream.removeListener(listener);
        oldStream.removeListener(listener);
        await _tick(tester);
        expect(cache.statusForKey(replacement).keepAlive, isTrue);
        expect(previous.codecs.single.disposals, 1);
        expect(replacement.codecs.single.disposals, 1);
      } finally {
        cache
          ..clear()
          ..clearLiveImages();
        await _tick(tester);
      }
    },
  );

  testWidgets('real animated WebP releases its native decoder after leaving', (
    tester,
  ) async {
    final files = _FileCache(
      File('test/common/widgets/image/fixtures/animated.webp').absolute,
    )..gate = Completer<void>();
    final provider = _NativeProvider(files);
    final first = provider.resolve(ImageConfiguration.empty)
      ..addListener(listener)
      ..removeListener(listener);
    expect(first.completer, isNotNull);
    files.gate!.complete();
    await _until(
      tester,
      () => provider.codecs.isNotEmpty && provider.codecs.single.disposals == 1,
    );
    expect(cache.statusForKey(provider).untracked, isTrue);
    var frames = 0;
    final viewer = ImageStreamListener((info, _) {
      frames++;
      info.dispose();
    });
    final restored = provider.resolve(ImageConfiguration.empty)
      ..addListener(viewer);
    try {
      await _until(tester, () => frames >= 2);
      expect(provider.codecs, hasLength(2));
      expect(provider.codecs.last.disposals, 0);
    } finally {
      restored.removeListener(viewer);
      await _until(tester, () => provider.codecs.last.disposals == 1);
      cache
        ..clear()
        ..clearLiveImages();
      await _tick(tester);
    }
    expect(tester.takeException(), isNull);
  });

  for (final phase in ['file', 'frame']) {
    testWidgets(
      'a resized image $phase failure leaves no pending cache entry',
      (
        tester,
      ) async {
        final provider = _Provider(
          'https://example.test/failed.gif',
          source,
          files,
        );
        final failure = StateError('synthetic $phase failure');
        if (phase == 'file') {
          files.failure = failure;
        } else {
          provider.frameFailure = failure;
        }
        final resized = ResizeImage(provider, width: 2);
        final key = await resized.obtainKey(ImageConfiguration.empty);
        final errors = <Object>[];
        final listener = ImageStreamListener(
          (info, _) => info.dispose(),
          onError: (error, _) => errors.add(error),
        );
        final stream = resized.resolve(ImageConfiguration.empty)
          ..addListener(listener);
        try {
          await _until(tester, () => errors.isNotEmpty);
          expect(errors.single, same(failure));
          stream.removeListener(listener);
          await _tick(tester);
          expect(cache.statusForKey(key).untracked, isTrue);
          expect(
            provider.codecs.every((codec) => codec.disposals == 1),
            isTrue,
          );
        } finally {
          cache
            ..clear()
            ..clearLiveImages();
          await _tick(tester);
        }
      },
    );
  }
}
