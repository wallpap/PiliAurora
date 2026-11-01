import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image_ce/src/image_provider/multi_image_stream_completer.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

class _Frame implements ui.FrameInfo {
  _Frame(this.image);
  @override
  final ui.Image image;
  @override
  Duration get duration => const Duration(milliseconds: 100);
}

class _Codec implements ui.Codec {
  _Codec(this.source, {this.frameCount = 1, this.gate});
  final ui.Image source;
  final Completer<ui.FrameInfo>? gate;
  final frames = <ui.Image>[];
  int disposals = 0;
  @override
  final int frameCount;
  @override
  int get repetitionCount => -1;
  @override
  Future<ui.FrameInfo> getNextFrame() {
    if (gate != null) return gate!.future;
    final image = source.clone();
    frames.add(image);
    return Future.value(_Frame(image));
  }

  @override
  void dispose() {
    disposals++;
  }
}

void main() {
  late ui.Image source;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff334455), ui.BlendMode.src);
    final picture = recorder.endRecording();
    source = await picture.toImage(2, 2);
    picture.dispose();
  });
  tearDownAll(() => source.dispose());

  testWidgets('last listener and keepAlive release static codec and frame', (
    tester,
  ) async {
    final stream = StreamController<ui.Codec>(sync: true);
    final codec = _Codec(source);
    final completer = MultiImageStreamCompleter(codec: stream.stream, scale: 1);
    final listener = ImageStreamListener((info, _) => info.dispose());
    completer.addListener(listener);
    final handle = completer.keepAlive();
    stream.add(codec);
    await tester.pump();
    completer.removeListener(listener);
    expect(codec.frames.single.debugDisposed, isFalse);
    handle.dispose();
    expect(codec.disposals, 1);
    expect(codec.frames.single.debugDisposed, isTrue);
    unawaited(stream.close());
    await tester.pump();
  });

  testWidgets('late frame and stream codec are released after final detach', (
    tester,
  ) async {
    final stream = StreamController<ui.Codec>(sync: true);
    final gate = Completer<ui.FrameInfo>();
    final codec = _Codec(source, gate: gate);
    final completer = MultiImageStreamCompleter(codec: stream.stream, scale: 1);
    var delivered = 0;
    final listener = ImageStreamListener((info, _) {
      delivered++;
      info.dispose();
    });
    completer.addListener(listener);
    stream.add(codec);
    completer.removeListener(listener);
    expect(codec.disposals, 0);
    final late = source.clone();
    gate.complete(_Frame(late));
    await tester.pump();
    expect(delivered, 0);
    expect(late.debugDisposed, isTrue);
    expect(codec.disposals, 1);
    final extra = _Codec(source);
    stream.add(extra);
    expect(extra.disposals, 1);
    unawaited(stream.close());
    await tester.pump();
  });

  testWidgets('animation replacement releases superseded queued codecs', (
    tester,
  ) async {
    final stream = StreamController<ui.Codec>(sync: true);
    final first = _Codec(source, frameCount: 2);
    final queued = _Codec(source);
    final replacement = _Codec(source);
    final completer = MultiImageStreamCompleter(codec: stream.stream, scale: 1);
    final listener = ImageStreamListener((info, _) => info.dispose());
    completer.addListener(listener);
    stream.add(first);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    stream
      ..add(queued)
      ..add(replacement);
    expect(queued.frames, isEmpty);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    completer.removeListener(listener);
    expect(queued.disposals, 1);
    expect(first.disposals, 1);
    expect(replacement.disposals, 1);
    expect(first.frames.every((image) => image.debugDisposed), isTrue);
    unawaited(stream.close());
    await tester.pump();
  });

  testWidgets(
    'replacement during decoding discards the old frame before resuming',
    (tester) async {
      final stream = StreamController<ui.Codec>(sync: true);
      final gate = Completer<ui.FrameInfo>();
      final first = _Codec(source, gate: gate);
      final replacement = _Codec(source);
      final completer = MultiImageStreamCompleter(
        codec: stream.stream,
        scale: 1,
      );
      var delivered = 0;
      final listener = ImageStreamListener((info, _) {
        delivered++;
        info.dispose();
      });
      completer.addListener(listener);
      stream
        ..add(first)
        ..add(replacement);
      expect(first.disposals, 0);
      final stale = source.clone();
      gate.complete(_Frame(stale));
      await tester.pump();
      expect(stale.debugDisposed, isTrue);
      expect(first.disposals, 1);
      expect(replacement.disposals, 1);
      expect(delivered, 1);
      completer.removeListener(listener);
      unawaited(stream.close());
      await tester.pump();
    },
  );
}
