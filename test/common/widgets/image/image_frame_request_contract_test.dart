import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';

class _Frame implements ui.FrameInfo {
  _Frame(this.image);
  @override
  final ui.Image image;
  @override
  Duration get duration => const Duration(milliseconds: 30);
}

class _Codec implements ui.Codec {
  _Codec(this.source);
  final ui.Image source;
  final started = Completer<void>();
  Completer<void>? gate;
  ui.Image? output;
  int requests = 0;
  int disposals = 0;
  @override
  int get frameCount => 12;
  @override
  int get repetitionCount => -1;
  @override
  Future<ui.FrameInfo> getNextFrame() async {
    requests++;
    if (!started.isCompleted) started.complete();
    await gate?.future;
    return _Frame(output = source.clone());
  }

  @override
  void dispose() => disposals++;
}

class _FileCache implements BaseCacheManager {
  _FileCache(this.file);
  final File file;
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool? withProgress,
  }) async* {
    yield FileInfo(file, FileSource.Cache, DateTime(2100), url);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File file;
  late ui.Image source;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('image-frame-contract-');
    file = await File('${directory.path}/encoded.bin').writeAsBytes([1]);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
    final picture = recorder.endRecording();
    source = picture.toImageSync(16, 8);
    picture.dispose();
  });
  tearDown(() async {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    source.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'one-shot animation decoding returns only frame zero and closes codec',
    () async {
      final codec = _Codec(source);
      final request = loadImageFrame(
        file,
        decode: (buffer, {getTargetSize}) async {
          buffer.dispose();
          return codec;
        },
      );
      final image = await request.result;
      await request.drained;
      expect(image, isNotNull);
      expect(codec.requests, 1);
      expect(codec.disposals, 1);
      expect(image!.debugDisposed, isFalse);
      request.cancel();
      expect(image.debugDisposed, isFalse);
      image.dispose();
    },
  );

  test(
    'a cancelled in-flight frame is released once without early codec disposal',
    () async {
      final codec = _Codec(source)..gate = Completer<void>();
      final request = loadImageFrame(
        file,
        decode: (buffer, {getTargetSize}) async {
          buffer.dispose();
          return codec;
        },
      );
      await codec.started.future;
      request.cancel();
      request.cancel();
      expect(codec.disposals, 0);
      codec.gate!.complete();
      expect(await request.result, isNull);
      await request.drained;
      expect(codec.disposals, 1);
      expect(codec.output!.debugDisposed, isTrue);
    },
  );

  test(
    'one-shot and Provider work share the same default native admission',
    () async {
      final codecs = List.generate(
        3,
        (_) => _Codec(source)..gate = Completer<void>(),
      );
      final created = List.generate(3, (_) => Completer<void>());
      Future<ui.Codec> decode(int index, ui.ImmutableBuffer buffer) async {
        buffer.dispose();
        created[index].complete();
        return codecs[index];
      }

      final first = loadImageFrame(
        file,
        decode: (buffer, {getTargetSize}) => decode(0, buffer),
      );
      final second = loadImageFrame(
        file,
        decode: (buffer, {getTargetSize}) => decode(1, buffer),
      );
      await Future.wait([codecs[0].started.future, codecs[1].started.future]);
      final provider = CachedImageProvider(
        'https://example.test/shared.png',
        cacheManager: _FileCache(file),
      );
      final stream = provider.loadImage(
        provider,
        (buffer, {getTargetSize}) => decode(2, buffer),
      );
      final delivered = Completer<void>();
      final listener = ImageStreamListener((info, _) {
        info.dispose();
        if (!delivered.isCompleted) delivered.complete();
      }, onError: delivered.completeError);
      stream.addListener(listener);
      await Future<void>.delayed(Duration.zero);
      expect(created[2].isCompleted, isFalse);
      first.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(created[2].isCompleted, isFalse);
      codecs[0].gate!.complete();
      await first.drained;
      await codecs[2].started.future;
      codecs[1].gate!.complete();
      codecs[2].gate!.complete();
      (await second.result)?.dispose();
      await delivered.future;
      stream.removeListener(listener);
      await second.drained;
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'local Provider honors framework decoder callback and target dimensions',
    () async {
      final provider = LocalImageProvider(file, width: 100);
      final sameKey = LocalImageProvider(File(file.path), width: 100);
      expect(provider, sameKey);
      expect(provider.hashCode, sameKey.hashCode);
      ui.TargetImageSize? target;
      final codec = _Codec(source);
      final delivered = Completer<void>();
      final stream = provider.loadImage(provider, (
        buffer, {
        getTargetSize,
      }) async {
        target = getTargetSize!(400, 8000);
        buffer.dispose();
        return codec;
      });
      final listener = ImageStreamListener((info, _) {
        info.dispose();
        if (!delivered.isCompleted) delivered.complete();
      }, onError: delivered.completeError);
      stream.addListener(listener);
      await delivered.future;
      expect(target!.width, 100);
      expect(target!.height, 2000);
      stream.removeListener(listener);
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'one-shot errors retain original cause and permit later decoding',
    () async {
      final cause = StateError('synthetic codec failure');
      final request = loadImageFrame(
        file,
        decode: (buffer, {getTargetSize}) async {
          buffer.dispose();
          throw cause;
        },
      );
      await expectLater(request.result, throwsA(same(cause)));
      await request.drained;
      final next = loadImageFrame(
        file,
        decode: (buffer, {getTargetSize}) async {
          buffer.dispose();
          return _Codec(source);
        },
      );
      (await next.result)!.dispose();
      await next.drained;
    },
  );
}
