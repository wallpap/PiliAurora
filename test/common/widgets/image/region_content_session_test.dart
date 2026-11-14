import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/image_resources.dart';
import 'package:pili_aurora/common/widgets/image/src/content_demand.dart';
import 'package:pili_aurora/common/widgets/image/src/image_source_store.dart';
import 'package:pili_aurora/common/widgets/image/src/region_content_session.dart';

ui.Image _pixels(int width, int height) {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(width, height);
  picture.dispose();
  return image;
}

class _Backend implements RegionImageBackend {
  _Backend(this.decoder);
  final _Decoder decoder;
  @override
  Future<RegionImageDecoder> open(ImageSourceLease source) async {
    decoder.source = source;
    decoder.version = source.version;
    return decoder;
  }
}

class _Decoder implements RegionImageDecoder {
  ImageSourceLease? source;
  Object? version;
  Completer<void>? regionGate;
  int disposals = 0;
  int baseCalls = 0;
  bool oversized = false;
  final requests = <RegionRequest>[];
  final outputs = <ui.Image>[];
  @override
  final sourceSize = const Size(4096, 8192);
  @override
  int frameCount = 1;
  @override
  bool hasBoundedBase = true;
  @override
  bool hasIndependentRegions = true;
  @override
  Future<RegionImage> decodeBase(int maximumPixels) async {
    baseCalls++;
    expect(await source!.file.readAsBytes(), [1, 2, 3]);
    final density = math.min(
      1.0,
      math.sqrt(maximumPixels / (sourceSize.width * sourceSize.height)),
    );
    final image = _pixels(
      (sourceSize.width * density).floor(),
      (sourceSize.height * density).floor(),
    );
    outputs.add(image);
    return RegionImage(
      image: image,
      sourceRect: Offset.zero & sourceSize,
      core: Offset.zero & sourceSize,
    );
  }

  @override
  Future<RegionImage> decodeRegion(RegionRequest request) async {
    requests.add(request);
    await regionGate?.future;
    expect(await source!.file.readAsBytes(), [1, 2, 3]);
    expect(source!.version, version);
    final divisor = math.pow(2, request.level);
    final image = _pixels(
      (request.read.width / divisor).ceil() + (oversized ? 1 : 0),
      (request.read.height / divisor).ceil(),
    );
    outputs.add(image);
    return RegionImage(
      image: image,
      sourceRect: request.read,
      core: request.core,
    );
  }

  @override
  void dispose() => disposals++;
}

Future<void> _until(bool Function() predicate) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('region operation did not settle');
}

class _BrokenDrainDecoder extends _Decoder
    implements DrainingRegionImageDecoder {
  final closed = Completer<void>();
  @override
  Future<void> get drained => closed.future;
  @override
  void dispose() {
    super.dispose();
    closed.completeError(StateError('injected-close'));
  }
}

class _WideDecoder extends _Decoder {
  @override
  Size get sourceSize => const Size(8192, 8192);
}

ContentDemand _demand(Rect rectangle, [double scale = 1]) =>
    ContentDemand(viewport: ContentViewport(rectangle, scale));

Future<void> _pumpDrained(
  WidgetTester tester,
  RegionContentSession session,
) async {
  var drained = false;
  session.drained.then((_) => drained = true);
  for (var attempt = 0; attempt < 100 && !drained; attempt++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(drained, isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File original;
  late ImageSourceStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('image-region-');
    original = await File('${directory.path}/original').writeAsBytes([1, 2, 3]);
    store = ImageSourceStore(Directory('${directory.path}/snapshots'));
  });
  tearDown(() async {
    await store.clear();
    await directory.delete(recursive: true);
  });

  test(
    'worker close error still releases images, budgets and source',
    () async {
      final resources = ImageResources(maximumRegionBytes: 24 << 10);
      final decoder = _BrokenDrainDecoder();
      final lease = await store.acquire(original);
      final session = RegionContentSession(
        source: lease,
        backend: _Backend(decoder),
        resources: resources,
        maximumBytes: 24 << 10,
        maximumBaseBytes: 4 << 10,
        tileSize: 32,
      )..update(_demand(const Rect.fromLTWH(0, 0, 32, 32)));
      await _until(() => session.value.images.length == 2);
      session.dispose();
      await expectLater(session.drained, throwsStateError);
      expect(resources.regionBytes, 0);
      expect(decoder.outputs.every((image) => image.debugDisposed), isTrue);
      expect(store.statistics['leases'], 0);
      expect(lease.file.existsSync(), isFalse);
      resources.dispose();
      await resources.drained;
    },
  );

  test(
    'oversized merged viewport signals fallback instead of staying blurry',
    () async {
      final resources = ImageResources(maximumRegionBytes: 128 << 20);
      final decoder = _WideDecoder();
      final session = RegionContentSession(
        source: await store.acquire(original),
        backend: _Backend(decoder),
        resources: resources,
        maximumBytes: 48 << 20,
        maximumBaseBytes: 4 << 20,
        coalesceViewport: true,
      )..update(_demand(const Rect.fromLTWH(0, 0, 5000, 5000), .6));
      await _until(() => session.value.images.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final error = session.value.error;
      session.dispose();
      await session.drained;
      resources.dispose();
      await resources.drained;
      expect(error, isA<UnsupportedError>());
      expect(decoder.requests, isEmpty);
      expect(store.statistics['leases'], 0);
    },
  );

  test(
    'base and overlapping detail use one immutable source and native sampling',
    () async {
      final resources = ImageResources(maximumRegionBytes: 32 << 10);
      final decoder = _Decoder();
      final lease = await store.acquire(original);
      final session = RegionContentSession(
        source: lease,
        backend: _Backend(decoder),
        resources: resources,
        maximumBytes: 24 << 10,
        maximumBaseBytes: 4 << 10,
        tileSize: 32,
      )..update(_demand(const Rect.fromLTWH(128, 256, 128, 128), .25));
      await _until(() => session.value.images.length == 2);
      expect(decoder.baseCalls, 1);
      expect(decoder.requests.single.level, 2);
      expect(
        decoder.requests.single.read,
        const Rect.fromLTRB(124, 252, 260, 388),
      );
      expect(session.value.version, lease.version);
      expect(session.value.sourceSize, decoder.sourceSize);
      expect(
        resources.regionBytes,
        lessThanOrEqualTo(resources.maximumRegionBytes),
      );
      session.update(_demand(const Rect.fromLTWH(128, 256, 32, 32), 2));
      await _until(() => decoder.requests.any((request) => request.level == 0));
      expect(session.value.sourceSize, decoder.sourceSize);
      session.dispose();
      await session.drained;
      expect(resources.regionBytes, 0);
      expect(decoder.disposals, 1);
      expect(decoder.outputs.every((image) => image.debugDisposed), isTrue);
      resources.dispose();
      await resources.drained;
    },
  );

  test(
    'multiple surfaces share retained and pending output reservations',
    () async {
      final resources = ImageResources(maximumRegionBytes: 16 << 10);
      final sessions = <RegionContentSession>[];
      for (var index = 0; index < 2; index++) {
        final session = RegionContentSession(
          source: await store.acquire(original),
          backend: _Backend(_Decoder()),
          resources: resources,
          maximumBytes: 16 << 10,
          maximumBaseBytes: 4 << 10,
          tileSize: 32,
        );
        sessions.add(session);
        session.update(_demand(const Rect.fromLTWH(0, 0, 64, 64)));
      }
      await _until(
        () => sessions.every((session) => session.value.images.isNotEmpty),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(resources.regionBytes, lessThanOrEqualTo(16 << 10));
      expect(
        sessions.fold(0, (sum, session) => sum + session.workingSetBytes),
        resources.regionBytes,
      );
      sessions.first.dispose();
      await sessions.first.drained;
      await _until(() => sessions.last.value.images.length > 1);
      expect(resources.regionBytes, lessThanOrEqualTo(16 << 10));
      sessions.last.dispose();
      await sessions.last.drained;
      expect(resources.regionBytes, 0);
      resources.dispose();
      await resources.drained;
    },
  );

  test(
    'native work keeps its source and reservation after session cancellation',
    () async {
      final resources = ImageResources(maximumRegionBytes: 24 << 10);
      final decoder = _Decoder()..regionGate = Completer<void>();
      final lease = await store.acquire(original);
      final session = RegionContentSession(
        source: lease,
        backend: _Backend(decoder),
        resources: resources,
        maximumBaseBytes: 4 << 10,
        maximumBytes: 24 << 10,
        tileSize: 32,
      )..update(_demand(const Rect.fromLTWH(0, 0, 32, 32)));
      await _until(() => decoder.requests.isNotEmpty);
      final before = resources.regionBytes;
      session.dispose();
      await store.clear();
      expect(lease.file.existsSync(), isTrue);
      expect(resources.regionBytes, before);
      expect(decoder.disposals, 0);
      decoder.regionGate!.complete();
      await session.drained;
      expect(lease.file.existsSync(), isFalse);
      expect(decoder.outputs.every((image) => image.debugDisposed), isTrue);
      expect(resources.regionBytes, 0);
      resources.dispose();
      await resources.drained;
    },
  );

  for (final unsupported in ['animation', 'base', 'regions']) {
    test(
      'unsupported $unsupported cannot silently fall back to a full decode',
      () async {
        final resources = ImageResources();
        final decoder = _Decoder();
        if (unsupported == 'animation') decoder.frameCount = 2;
        if (unsupported == 'base') decoder.hasBoundedBase = false;
        if (unsupported == 'regions') decoder.hasIndependentRegions = false;
        final session = RegionContentSession(
          source: await store.acquire(original),
          backend: _Backend(decoder),
          resources: resources,
        )..update(_demand(const Rect.fromLTWH(0, 0, 32, 32)));
        await _until(() => session.value.error != null);
        expect(decoder.baseCalls, 0);
        expect(decoder.requests, isEmpty);
        expect(session.value.images, isEmpty);
        expect(decoder.disposals, 1);
        session.dispose();
        await session.drained;
        resources.dispose();
        await resources.drained;
      },
    );
  }

  test(
    'a backend that exceeds its output contract preserves only the safe base',
    () async {
      final resources = ImageResources();
      final decoder = _Decoder()..oversized = true;
      final session = RegionContentSession(
        source: await store.acquire(original),
        backend: _Backend(decoder),
        resources: resources,
        maximumBytes: 24 << 10,
        maximumBaseBytes: 4 << 10,
        tileSize: 32,
      )..update(_demand(const Rect.fromLTWH(0, 0, 32, 32)));
      await _until(() => session.value.error != null);
      expect(session.value.images, hasLength(1));
      expect(decoder.outputs.last.debugDisposed, isTrue);
      expect(
        resources.regionBytes,
        decoder.outputs.first.width * decoder.outputs.first.height * 4,
      );
      session.dispose();
      await session.drained;
      resources.dispose();
      await resources.drained;
    },
  );

  testWidgets(
    'retired details remain charged until the current surface can repaint',
    (tester) async {
      final resources = ImageResources(maximumRegionBytes: 24 << 10);
      final decoder = _Decoder();
      final source = await tester.runAsync(() => store.acquire(original));
      final session = RegionContentSession(
        source: source!,
        backend: _Backend(decoder),
        resources: resources,
        maximumBytes: 24 << 10,
        maximumBaseBytes: 4 << 10,
        tileSize: 32,
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 200,
            height: 200,
            child: RegionImageSurface(session: session),
          ),
        ),
      );
      await tester.runAsync(() async {
        session.update(_demand(const Rect.fromLTWH(0, 0, 32, 32)));
        await _until(() => session.value.images.length == 2);
      });
      await tester.pump();
      final oldDetail = session.value.images.last.image;
      decoder.regionGate = Completer<void>();
      await tester.runAsync(() async {
        session.update(_demand(const Rect.fromLTWH(128, 128, 32, 32)));
        await _until(() => decoder.requests.length == 2);
      });
      expect(oldDetail.debugDisposed, isFalse);
      expect(resources.regionBytes, session.workingSetBytes);
      await tester.pump();
      expect(oldDetail.debugDisposed, isTrue);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        decoder.regionGate!.complete();
        await _until(() => session.value.images.length == 2);
        session.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpDrained(tester, session);
      expect(resources.regionBytes, 0);
      resources.dispose();
      await resources.drained;
    },
  );

  testWidgets(
    'detach and reattach before retirement keeps close waiting for paint',
    (tester) async {
      final resources = ImageResources(maximumRegionBytes: 24 << 10);
      final decoder = _Decoder();
      final source = await tester.runAsync(() => store.acquire(original));
      final session = RegionContentSession(
        source: source!,
        backend: _Backend(decoder),
        resources: resources,
        maximumBytes: 24 << 10,
        maximumBaseBytes: 4 << 10,
        tileSize: 32,
      );
      final firstSurface = session.attachSurface();
      await tester.runAsync(() async {
        session.update(_demand(const Rect.fromLTWH(0, 0, 32, 32)));
        await _until(() => session.value.images.length == 2);
        decoder.regionGate = Completer<void>();
        session.update(_demand(const Rect.fromLTWH(128, 128, 32, 32)));
        await _until(() => decoder.requests.length == 2);
      });
      firstSurface();
      final nextSurface = session.attachSurface();
      var drained = false;
      session.drained.then((_) => drained = true);
      await tester.runAsync(() async {
        session.dispose();
        decoder.regionGate!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      expect(drained, isFalse);
      expect(resources.regionBytes, greaterThan(0));
      await tester.pump();
      await _pumpDrained(tester, session);
      expect(resources.regionBytes, 0);
      nextSurface();
      resources.dispose();
      await resources.drained;
    },
  );
}
