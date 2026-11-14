import 'native_fixture_support.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/content_image.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';
import 'package:pili_aurora/common/widgets/image/src/content_demand.dart';
import 'package:pili_aurora/common/widgets/image/src/native_worker_backend.dart';
import 'package:pili_aurora/common/widgets/image/src/region_content_session.dart';
import 'package:pili_aurora/utils/cache_manager.dart' as app_cache;

class _Cache implements BaseCacheManager {
  _Cache(this.file);
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
  observeNativeWorkers();
  final fixtures = nativeFixtures;
  File fixture(String id) => File(
    (fixtures.cast<Map>().singleWhere((e) => e['id'] == id))['file'] as String,
  );
  late Directory directory;
  final imageErrors = <String>[];
  setUp(imageErrors.clear);
  setUpAll(() async {
    expect(nativeFixtureAvailable, isTrue);
    directory = await Directory.systemTemp.createTemp('region-widget-native-');
    app_cache.CacheManager.manager = await DefaultCacheManager.init(
      cacheDirectoryProvider: () async => Directory('${directory.path}/cache'),
    );
    await app_cache.CacheManager.imageSources.ready;
  });
  tearDownAll(() async {
    await DefaultCacheManager.instance!.dispose();
    await directory.delete(recursive: true);
  });
  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 1000; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      if (ready()) return;
    }
    fail(
      'native widget did not reach required state: errors=$imageErrors workers=${nativeWorkers.length} leases=${app_cache.CacheManager.imageSources.statistics} events=${nativeWorkerEvents.skip(nativeWorkerEvents.length > 8 ? nativeWorkerEvents.length - 8 : 0).toList()}',
    );
  }

  Widget host(File file, ValueNotifier<ContentViewport?> viewport, String id) =>
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 1),
          child: Center(
            child: SizedBox(
              width: 600,
              height: 400,
              child: ContentImage.network(
                'https://fixture.invalid/$id',
                cacheManager: _Cache(file),
                viewport: viewport,
                errorBuilder: (_, error, stack) {
                  if (!imageErrors.contains(error.toString())) {
                    imageErrors.add(error.toString());
                  }
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await until(
      tester,
      () =>
          nativeWorkers.isEmpty &&
          app_cache.CacheManager.imageSources.statistics.values.every(
            (v) => v == 0,
          ),
    );
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  nativeTestWidgets(
    'real ContentImage switches static detail, oversized fallback and animation in one session',
    (tester) async {
      {
        final viewport = ValueNotifier<ContentViewport?>(
          const ContentViewport(Rect.fromLTWH(0, 0, 8192, 3972), .15),
        );
        await tester.pumpWidget(host(fixture('wide'), viewport, 'static'));
        await until(tester, () {
          final found = find.byType(RegionImageSurface).evaluate();
          if (found.isEmpty) return false;
          final surface = found.single.widget as RegionImageSurface;
          return surface.session.value.images.any(
            (image) => image.image.width / image.sourceRect.width >= .15,
          );
        });
        expect(
          find.byWidgetPredicate((w) => w is RawImage && w.image != null),
          findsNothing,
        );
        final surface = tester.widget<RegionImageSurface>(
          find.byType(RegionImageSurface),
        );
        expect(surface.session.value.sourceSize, const Size(8192, 3972));
        expect(
          surface.session.value.images.last.image.width / 8192,
          greaterThanOrEqualTo(.15),
        );
        await close(tester);
        viewport.dispose();
      }
      {
        final viewport = ValueNotifier<ContentViewport?>(
          const ContentViewport(Rect.fromLTWH(0, 0, 8192, 3972), 1),
        );
        await tester.pumpWidget(host(fixture('wide'), viewport, 'large'));
        final pixels = find.byWidgetPredicate(
          (w) => w is RawImage && w.image != null,
        );
        await until(
          tester,
          () => pixels.evaluate().isNotEmpty && nativeWorkers.isEmpty,
        );
        expect(find.byType(RegionImageSurface), findsNothing);
        final image = tester.widget<RawImage>(pixels).image!;
        expect(image.width, 8192);
        expect(image.height, 3972);
        await close(tester);
        viewport.dispose();
      }
      {
        final eventStart = nativeWorkerEvents.length;
        final viewport = ValueNotifier<ContentViewport?>(
          const ContentViewport(Rect.fromLTWH(0, 0, 1600, 1000), .5),
        );
        await tester.pumpWidget(
          host(fixture('animated'), viewport, 'animated'),
        );
        final pixels = find.byWidgetPredicate(
          (w) => w is RawImage && w.image != null,
        );
        await until(
          tester,
          () => pixels.evaluate().isNotEmpty && nativeWorkers.isEmpty,
        );
        expect(find.byType(RegionImageSurface), findsNothing);
        expect(app_cache.CacheManager.imageSources.statistics['leases'], 0);
        expect(nativeWorkerEvents.skip(eventStart), isEmpty);
        await close(tester);
        viewport.dispose();
      }
      {
        final viewport = ValueNotifier<ContentViewport?>(
          const ContentViewport(Rect.fromLTWH(0, 0, 720, 550), .5),
        );
        await tester.pumpWidget(
          host(fixture('oriented'), viewport, 'oriented'),
        );
        final pixels = find.byWidgetPredicate(
          (w) => w is RawImage && w.image != null,
        );
        await until(
          tester,
          () => pixels.evaluate().isNotEmpty && nativeWorkers.isEmpty,
        );
        expect(find.byType(RegionImageSurface), findsNothing);
        final image = tester.widget<RawImage>(pixels).image!;
        expect(image.width, 550);
        expect(image.height, 720);
        await close(tester);
        viewport.dispose();
      }
      {
        final viewport = ValueNotifier<ContentViewport?>(
          const ContentViewport(Rect.fromLTWH(0, 0, 8192, 3972), .15),
        );
        final load = ValueNotifier(true);
        Widget local() => Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(devicePixelRatio: 1),
            child: Center(
              child: SizedBox(
                width: 600,
                height: 400,
                child: ValueListenableBuilder<bool>(
                  valueListenable: load,
                  builder: (_, enabled, _) => ImageLoadingScope(
                    enabled: enabled,
                    child: ContentImage.file(
                      fixture('wide'),
                      viewport: viewport,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpWidget(local());
        await until(
          tester,
          () => find.byType(RegionImageSurface).evaluate().isNotEmpty,
        );
        load.value = false;
        await until(
          tester,
          () =>
              nativeWorkers.isEmpty &&
              app_cache.CacheManager.imageSources.statistics['leases'] == 0,
        );
        expect(find.byType(RegionImageSurface), findsNothing);
        load.value = true;
        await until(
          tester,
          () => find.byType(RegionImageSurface).evaluate().isNotEmpty,
        );
        await close(tester);
        viewport.dispose();
        load.dispose();
      }
      {
        final viewport = ValueNotifier<ContentViewport?>(
          const ContentViewport(Rect.fromLTWH(0, 0, 600, 400), .5),
        );
        await tester.pumpWidget(
          host(fixture('huge-webp'), viewport, 'huge-webp'),
        );
        final pixels = find.byWidgetPredicate(
          (w) => w is RawImage && w.image != null,
        );
        await until(
          tester,
          () => pixels.evaluate().isNotEmpty && nativeWorkers.isEmpty,
        );
        expect(tester.widget<RawImage>(pixels).image!.width, 8192);
        expect(find.byType(RegionImageSurface), findsNothing);
        await close(tester);
        viewport.dispose();
      }
      expect(imageErrors, isEmpty);
      {
        final viewport = ValueNotifier<ContentViewport?>(
          const ContentViewport(Rect.fromLTWH(0, 0, 720, 550), .5),
        );
        Object? referenceError;
        await tester.runAsync(() async {
          ui.Codec? codec;
          try {
            codec = await ui.instantiateImageCodec(
              await fixture('avif').readAsBytes(),
            );
            final frame = await codec.getNextFrame();
            frame.image.dispose();
          } catch (error) {
            referenceError = error;
          } finally {
            codec?.dispose();
          }
        });
        await tester.pumpWidget(host(fixture('avif'), viewport, 'avif'));
        final pixels = find.byWidgetPredicate(
          (w) => w is RawImage && w.image != null,
        );
        await until(
          tester,
          () =>
              nativeWorkers.isEmpty &&
              (referenceError == null
                  ? pixels.evaluate().isNotEmpty
                  : imageErrors.isNotEmpty),
        );
        if (referenceError == null) {
          expect(tester.widget<RawImage>(pixels).image!.width, 720);
          expect(imageErrors, isEmpty);
        } else {
          // Flutter 的格式能力随引擎而定，回退结果须与独立完整帧参照一致。
          expect(imageErrors, [referenceError.toString()]);
          imageErrors.clear();
        }
        expect(find.byType(RegionImageSurface), findsNothing);
        await close(tester);
        viewport.dispose();
      }
      // 同一测试内复用来源队列，避免 Future 绑定到已结束的 FakeAsync 区域。
      nativeWorkerEvents.clear();
      final viewport = ValueNotifier<ContentViewport?>(
        const ContentViewport(Rect.fromLTWH(0, 0, 8192, 3972), .15),
      );
      Widget content(bool enabled) => TickerMode(
        enabled: enabled,
        child: host(fixture('wide'), viewport, 'failed-worker'),
      );
      await tester.pumpWidget(content(true));
      await until(tester, () {
        final surfaces = find.byType(RegionImageSurface).evaluate();
        if (surfaces.isEmpty) return false;
        return (surfaces.single.widget as RegionImageSurface)
            .session
            .value
            .images
            .isNotEmpty;
      });
      nativeWorkers.single.process.kill();
      viewport.value = const ContentViewport(
        Rect.fromLTWH(3000, 1500, 600, 400),
        1,
      );
      await until(
        tester,
        () => imageErrors.isNotEmpty && nativeWorkers.isEmpty,
      );
      await tester.pumpWidget(content(false));
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      expect(find.byType(RegionImageSurface), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is RawImage && widget.image != null,
        ),
        findsNothing,
      );
      expect(
        nativeWorkerEvents.where((event) => event['event'] == 'open'),
        hasLength(1),
      );
      await close(tester);
      viewport.dispose();
    },
  );
}
