import 'dart:ui' as ui;

import 'package:canvas_danmaku/base_danmaku_painter.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/raster_cache.dart';
import 'package:pili_aurora/pages/danmaku/windows_renderer.dart';

const _size = Size(320, 120);
const _option = DanmakuOption(fontSize: 20, duration: 2, staticDuration: 1);

DanmakuContentItem<void> _text(
  String text, {
  DanmakuItemType type = DanmakuItemType.scroll,
  bool selfSend = false,
}) => DanmakuContentItem<void>(
  text,
  color: const Color(0xFFFFFFFF),
  type: type,
  selfSend: selfSend,
);

Future<List<int>> _pixels(void Function(Canvas) paint) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawRect(
      Offset.zero & _size,
      Paint()..color = const Color(0xFF205080),
    );
  paint(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    _size.width.toInt(),
    _size.height.toInt(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final pixels = bytes!.buffer.asUint8List().toList();
  image.dispose();
  picture.dispose();
  return pixels;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<List<int>> groupOracle(
    WindowsDanmakuRenderer<void> renderer,
    double opacity,
  ) => _pixels((canvas) {
    canvas.saveLayer(
      Offset.zero & _size,
      Paint()..color = Color.fromRGBO(255, 255, 255, opacity),
    );
    renderer.paint(canvas, _size);
    canvas.restore();
  });

  int maxDifference(List<int> a, List<int> b) {
    var result = 0;
    for (var index = 0; index < a.length; index++) {
      final difference = (a[index] - b[index]).abs();
      if (difference > result) result = difference;
    }
    return result;
  }

  test(
    'identical overlapping text needs group alpha, with endpoint coverage',
    () async {
      final renderer = WindowsDanmakuRenderer<void>(
        option: _option.copyWith(area: 0.3, safeArea: false, massiveMode: true),
        size: _size,
      );
      addTearDown(renderer.dispose);
      expect(renderer.add(_text('MMMM', selfSend: true)), isTrue);
      expect(renderer.add(_text('MMMM', selfSend: true)), isTrue);
      renderer.advance(const Duration(milliseconds: 500));
      final items = renderer.scrollDanmaku.single;
      expect(items.length, 2);
      expect(items[0].xPosition, items[1].xPosition);
      expect(items[0].width, items[1].width);
      for (final opacity in [0.0, 0.25, 0.5, 1.0]) {
        final groupBefore = renderer.groupPaints;
        final directBefore = renderer.directPaints;
        final actual = await _pixels(
          (canvas) => renderer.paint(canvas, _size, opacity: opacity),
        );
        expect(
          renderer.groupPaints - groupBefore,
          opacity > 0 && opacity < 1 ? 1 : 0,
        );
        expect(renderer.directPaints - directBefore, opacity == 1 ? 1 : 0);
        expect(
          maxDifference(actual, await groupOracle(renderer, opacity)),
          lessThanOrEqualTo(1),
          reason: 'opacity=$opacity',
        );
      }
      final expected = await groupOracle(renderer, 0.5);
      final individuallyTransparent = await _pixels((canvas) {
        for (final item in items) {
          canvas.drawImage(
            item.image!,
            Offset(item.xPosition, 0),
            Paint()..color = const Color.fromRGBO(255, 255, 255, 0.5),
          );
        }
      });
      expect(maxDifference(individuallyTransparent, expected), greaterThan(1));
    },
  );

  for (final ratio in [1.0, 2.0]) {
    test('separated tracks match group alpha at DPR $ratio', () async {
      final renderer = WindowsDanmakuRenderer<void>(
        option: _option,
        size: _size,
        devicePixelRatio: ratio,
      );
      addTearDown(renderer.dispose);
      expect(renderer.add(_text('top', type: DanmakuItemType.top)), isTrue);
      expect(
        renderer.add(_text('bottom', type: DanmakuItemType.bottom)),
        isTrue,
      );
      expect(renderer.canPaintDirectly, isTrue);
      if (ratio == 2) {
        final item = renderer.staticDanmaku
            .whereType<DanmakuItem<void>>()
            .first;
        expect(item.image!.width, isNot(item.width.ceil()));
      }
      for (final opacity in [0.25, 0.5, 1.0]) {
        final groupBefore = renderer.groupPaints;
        final directBefore = renderer.directPaints;
        final actual = await _pixels(
          (canvas) => renderer.paint(canvas, _size, opacity: opacity),
        );
        expect(renderer.groupPaints, groupBefore);
        expect(renderer.directPaints, directBefore + 1);
        expect(
          maxDifference(actual, await groupOracle(renderer, opacity)),
          lessThanOrEqualTo(1),
        );
      }
    });
  }

  test('special alpha is multiplied by whole-overlay opacity', () async {
    final renderer = WindowsDanmakuRenderer<void>(option: _option, size: _size);
    addTearDown(renderer.dispose);
    expect(
      renderer.add(
        SpecialDanmakuContentItem<void>(
          'MMMM',
          duration: 2000,
          color: const Color(0xFFFFFFFF),
          fontSize: 20,
          alphaTween: ConstantTween<double>(0.5),
          translateXTween: ConstantTween<double>(0.25),
          translateYTween: ConstantTween<double>(0.25),
        ),
      ),
      isTrue,
    );
    renderer.advance(const Duration(milliseconds: 500));
    final background = await _pixels((_) {});
    for (final opacity in [0.0, 0.25, 0.5, 1.0]) {
      final before = renderer.groupPaints;
      final actual = await _pixels(
        (canvas) => renderer.paint(canvas, _size, opacity: opacity),
      );
      expect(renderer.groupPaints - before, opacity > 0 && opacity < 1 ? 1 : 0);
      expect(
        maxDifference(actual, await groupOracle(renderer, opacity)),
        lessThanOrEqualTo(1),
      );
      if (opacity > 0) {
        expect(maxDifference(actual, background), greaterThan(1));
      }
    }
    final half = await _pixels(
      (canvas) => renderer.paint(canvas, _size, opacity: 0.5),
    );
    final opaque = await _pixels((canvas) => renderer.paint(canvas, _size));
    // 对所有有贡献的像素检查外部透明度的折半效应，避免只检查分支。
    for (var index = 0; index < half.length; index++) {
      if (index % 4 == 3) continue;
      expect(
        ((half[index] - background[index]) * 2 -
                (opaque[index] - background[index]))
            .abs(),
        lessThanOrEqualTo(2),
      );
    }
  });

  test('cache budgets are injectable without changing production defaults', () {
    final defaults = WindowsDanmakuRenderer<void>(option: _option, size: _size);
    expect(defaults.statistics['cacheImageLimitBytes'], 16 * 1024 * 1024);
    expect(defaults.statistics['cacheEntryLimit'], 512);
    final custom = WindowsDanmakuRenderer<void>(
      option: _option,
      size: _size,
      rasterCacheMaxBytes: 24 * 1024 * 1024,
      rasterCacheMaxEntries: 128,
    );
    expect(custom.statistics['cacheImageLimitBytes'], 24 * 1024 * 1024);
    expect(custom.statistics['cacheEntryLimit'], 128);
    defaults.dispose();
    custom.dispose();
  });

  test('cache attributes evictions to bytes or entry pressure', () {
    final entryLimited =
        DanmakuRasterCache(
            option: _option,
            devicePixelRatio: 1,
            maxEntries: 1,
          )
          ..get(_text('aa'), rasterize: true)
          ..get(_text('bb'), rasterize: true);
    expect(entryLimited.evictions, 1);
    expect(entryLimited.evictionsByEntries, 1);
    expect(entryLimited.evictionsByBytes, 0);
    final bytes = entryLimited.bytes;
    entryLimited.clear();
    final byteLimited =
        DanmakuRasterCache(
            option: _option,
            devicePixelRatio: 1,
            maxBytes: bytes,
          )
          ..get(_text('aa'), rasterize: true)
          ..get(_text('bb'), rasterize: true);
    expect(byteLimited.evictions, 1);
    expect(byteLimited.evictionsByBytes, 1);
    expect(byteLimited.evictionsByEntries, 0);
    expect(byteLimited.bytes, lessThanOrEqualTo(bytes));
    byteLimited.clear();
  });

  test('trajectory clock retains sub-millisecond frame time', () {
    final first = WindowsDanmakuRenderer<void>(option: _option, size: _size)
      ..add(_text('moving'));
    final second = WindowsDanmakuRenderer<void>(option: _option, size: _size)
      ..add(_text('moving'));
    for (var index = 0; index < 60; index++) {
      first.advance(const Duration(microseconds: 16666));
    }
    for (var index = 0; index < 120; index++) {
      second.advance(const Duration(microseconds: 8333));
    }
    expect(first.tick, 999);
    expect(second.tick, first.tick);
    expect(
      second.scrollDanmaku.first.single.xPosition,
      first.scrollDanmaku.first.single.xPosition,
    );
    first.dispose();
    second.dispose();
  });

  test('prewarm is bounded, paused safely and invalidated by settings', () {
    final renderer = WindowsDanmakuRenderer<void>(option: _option, size: _size)
      ..queuePrewarm(List.generate(100, (index) => _text('future $index')));
    expect(renderer.statistics['pendingPrewarm'], 64);
    renderer
      ..pause()
      ..prewarmPending();
    expect(renderer.rasters.rasterizations, 0);
    renderer
      ..resume()
      ..prewarmPending();
    expect(renderer.rasters.rasterizations, inInclusiveRange(1, 4));
    renderer.configure(devicePixelRatio: 2);
    expect(renderer.statistics['pendingPrewarm'], 0);
    expect(renderer.rasters.length, 0);
    renderer.dispose();
  });

  test('prewarm skips content already rasterized', () {
    final renderer = WindowsDanmakuRenderer<void>(option: _option, size: _size)
      ..add(_text('cached'));
    final rasterizations = renderer.rasters.rasterizations;
    renderer.queuePrewarm([_text('cached')]);
    expect(renderer.statistics['pendingPrewarm'], 0);
    expect(renderer.rasters.rasterizations, rasterizations);
    renderer.dispose();
  });

  test('overlapping self-sent items use group opacity and active count stays bounded', () {
    final renderer = WindowsDanmakuRenderer<void>(
      option: _option.copyWith(area: 0.3, safeArea: false, massiveMode: true),
      size: _size,
    );
    expect(renderer.controller.trackCount, 1);
    expect(renderer.add(_text('one', selfSend: true)), isTrue);
    expect(renderer.add(_text('two', selfSend: true)), isTrue);
    expect(renderer.canPaintDirectly, isFalse);
    for (var index = 2; index < 600; index++) {
      expect(renderer.add(_text('repeat')), isTrue);
    }
    expect(renderer.add(_text('overflow')), isFalse);
    expect(renderer.rasters.rasterizations, 3);
    renderer.clear();
    expect(renderer.activeBytes, 0);
    renderer.dispose();
  });

  test('special text retains its timeline after DPI changes', () {
    final content = SpecialDanmakuContentItem<void>(
      'special',
      duration: 2000,
      color: const Color(0xFFFFFFFF),
      fontSize: 20,
      translateXTween: ConstantTween<double>(0.5),
      translateYTween: ConstantTween<double>(0.5),
    );
    final renderer = WindowsDanmakuRenderer<void>(option: _option, size: _size)
      ..add(content)
      ..advance(const Duration(milliseconds: 500));
    expect(renderer.canPaintDirectly, isFalse);
    renderer.configure(devicePixelRatio: 2);
    expect(renderer.specialDanmaku.single.drawTick, 0);
    renderer.advance(const Duration(milliseconds: 1500));
    expect(renderer.isEmpty, isTrue);
    expect(renderer.activeBytes, 0);
    renderer.dispose();
  });

  test(
    'one image is shared by repeated text, clone survives cache eviction',
    () {
      final cache = DanmakuRasterCache(
        option: _option,
        devicePixelRatio: 1,
        maxEntries: 1,
      );
      final first = cache.get(_text('first'), rasterize: true)!;
      final clone = first.image!.clone();
      expect(cache.get(_text('first'), rasterize: true), same(first));
      expect(cache.rasterizations, 1);
      cache.get(_text('second'), rasterize: true);
      expect(cache.length, 1);
      expect(cache.evictions, 1);
      expect(clone.width, greaterThan(0));
      clone.dispose();
      cache.clear();
      expect(cache.bytes, 0);
    },
  );

  test('image byte budget is bounded and oversized text is rejected', () {
    final cache = DanmakuRasterCache(
      option: _option,
      devicePixelRatio: 2,
      maxBytes: 64 * 1024,
      maxItemBytes: 64 * 1024,
    );
    for (var index = 0; index < 20; index++) {
      cache.get(_text('image $index'), rasterize: true);
      expect(cache.bytes, lessThanOrEqualTo(cache.maxBytes));
    }
    expect(cache.get(_text('x' * 10000), rasterize: true), isNull);
    cache.clear();
  });

  test('motion advances without paint and expires while offstage', () {
    final renderer = WindowsDanmakuRenderer<void>(option: _option, size: _size);
    expect(renderer.add(_text('moving')), isTrue);
    final item = renderer.scrollDanmaku.first.single;
    renderer.advance(const Duration(milliseconds: 500));
    expect(item.xPosition, lessThan(_size.width));
    renderer.pause();
    final paused = item.xPosition;
    renderer.advance(const Duration(seconds: 1));
    expect(item.xPosition, paused);
    renderer
      ..resume()
      ..advance(const Duration(seconds: 2));
    expect(renderer.isEmpty, isTrue);
    expect(renderer.scrollDanmaku.every((track) => track.isEmpty), isTrue);
    expect(renderer.activeBytes, 0);
    renderer.dispose();
  });

  test('static text does not notify paint on every tick', () {
    final renderer = WindowsDanmakuRenderer<void>(option: _option, size: _size)
      ..add(_text('static', type: DanmakuItemType.top));
    var repaints = 0;
    renderer
      ..addListener(() => repaints++)
      ..advance(const Duration(milliseconds: 500));
    expect(repaints, 0);
    renderer.advance(const Duration(milliseconds: 500));
    expect(repaints, 1);
    expect(renderer.isEmpty, isTrue);
    renderer.dispose();
  });

  test(
    'settings and DPI invalidate cached images without losing active text',
    () {
      final renderer =
          WindowsDanmakuRenderer<void>(
              option: _option,
              size: _size,
            )
            ..add(_text('moving'))
            ..advance(const Duration(milliseconds: 500));
      final before = renderer.scrollDanmaku.first.single.xPosition;
      renderer.configure(devicePixelRatio: 2);
      expect(
        renderer.scrollDanmaku.first.single.xPosition,
        closeTo(before, 0.01),
      );
      expect(renderer.rasters.rasterizations, 2);
      renderer.updateOption(_option.copyWith(duration: 1));
      expect(
        renderer.scrollDanmaku.first.single.xPosition,
        closeTo(before, 0.01),
      );
      renderer.advance(const Duration(milliseconds: 751));
      expect(renderer.isEmpty, isTrue);
      renderer.configure(size: Size.zero);
      expect(renderer.controller.trackCount, 0);
      expect(renderer.add(_text('no track')), isFalse);
      renderer.dispose();
    },
  );

  test('self-sent and static overlaps conservatively use group opacity', () {
    final renderer = WindowsDanmakuRenderer<void>(option: _option, size: _size)
      ..add(_text('top', type: DanmakuItemType.top));
    expect(renderer.canPaintDirectly, isTrue);
    renderer.add(_text('scroll'));
    expect(renderer.canPaintDirectly, isFalse);
    renderer.advance(const Duration(milliseconds: 1001));
    expect(renderer.canPaintDirectly, isTrue);
    renderer
      ..clear()
      ..add(_text('one', selfSend: true))
      ..add(_text('two', selfSend: true));
    expect(renderer.canPaintDirectly, isTrue);
    renderer.dispose();
  });

  for (final overlap in [false, true]) {
    test('pixel composition matches group opacity, overlap=$overlap', () async {
      final renderer = WindowsDanmakuRenderer<void>(
        option: _option,
        size: _size,
      )..add(_text('scroll'));
      if (overlap) renderer.add(_text('top', type: DanmakuItemType.top));
      renderer.advance(const Duration(milliseconds: 700));
      final actual = await _pixels(
        (canvas) => renderer.paint(canvas, _size, opacity: 0.5),
      );
      final expected = await _pixels((canvas) {
        canvas.saveLayer(
          Offset.zero & _size,
          Paint()..color = const Color.fromRGBO(255, 255, 255, 0.5),
        );
        for (var track = 0; track < renderer.scrollDanmaku.length; track++) {
          for (final item in renderer.scrollDanmaku[track]) {
            BaseDanmakuPainter.paintImg(
              canvas,
              item,
              item.xPosition,
              track * 32,
            );
          }
        }
        for (var track = 0; track < renderer.staticDanmaku.length; track++) {
          final item = renderer.staticDanmaku[track];
          if (item != null) {
            BaseDanmakuPainter.paintImg(
              canvas,
              item,
              item.xPosition,
              track * 32,
            );
          }
        }
        canvas.restore();
      });
      var maxDifference = 0;
      for (var index = 0; index < actual.length; index++) {
        final difference = (actual[index] - expected[index]).abs();
        if (difference > maxDifference) maxDifference = difference;
      }
      expect(maxDifference, lessThanOrEqualTo(overlap ? 0 : 1));
      expect(renderer.groupPaints, overlap ? 1 : 0);
      renderer.dispose();
    });
  }

  WindowsDanmakuRenderer<void> singleTrack({
    bool static2Scroll = false,
    bool hideScroll = false,
    bool massiveMode = false,
  }) => WindowsDanmakuRenderer<void>(
    option: _option.copyWith(
      area: 0.3,
      safeArea: false,
      static2Scroll: static2Scroll,
      hideScroll: hideScroll,
      massiveMode: massiveMode,
    ),
    size: _size,
  );

  test('massive mode does not bypass the shared top/bottom static pool', () {
    final renderer = singleTrack(massiveMode: true);
    addTearDown(renderer.dispose);
    expect(renderer.controller.trackCount, 1);
    expect(renderer.add(_text('top', type: DanmakuItemType.top)), isTrue);
    expect(
      renderer.add(_text('bottom', type: DanmakuItemType.bottom)),
      isFalse,
    );
    expect(renderer.statistics['rejectedByTrack'], 1);
    expect(renderer.scrollDanmaku.single, isEmpty);
    renderer.advance(const Duration(milliseconds: 999));
    expect(renderer.add(_text('top2', type: DanmakuItemType.top)), isFalse);
    renderer.advance(const Duration(milliseconds: 1));
    expect(
      renderer.add(_text('bottom2', type: DanmakuItemType.bottom)),
      isTrue,
    );
    expect(renderer.statistics['rejectedByTrack'], 2);
    renderer.clear();
    expect(renderer.statistics['rejectedByTrack'], 2);
  });

  for (final hideScroll in [true, false]) {
    for (final oversized in [false, true]) {
      test(
        'static fallback respects hideScroll=$hideScroll, oversized=$oversized',
        () {
          final renderer = singleTrack(
            static2Scroll: true,
            hideScroll: hideScroll,
          );
          addTearDown(renderer.dispose);
          expect(renderer.controller.trackCount, 1);
          if (!oversized) {
            expect(
              renderer.add(_text('occupied', type: DanmakuItemType.top)),
              isTrue,
            );
          }
          final content = _text(
            oversized ? 'x' * 70 : 'fallback',
            type: DanmakuItemType.bottom,
          );
          expect(renderer.add(content), !hideScroll);
          expect(renderer.scrollDanmaku.single.length, hideScroll ? 0 : 1);
          expect(renderer.statistics['rejectedByTrack'], hideScroll ? 1 : 0);
          expect(renderer.statistics['rejectedByRaster'], 0);
          expect(renderer.statistics['rejectedByMemoryBudget'], 0);
        },
      );
    }
  }

  test('normal scrolling rejects a same-tick burst without counting it as raster failure', () {
    final renderer = singleTrack();
    addTearDown(renderer.dispose);
    expect(renderer.add(_text('burst')), isTrue);
    expect(renderer.add(_text('burst')), isFalse);
    expect(renderer.statistics['rejectedByTrack'], 1);
    expect(renderer.statistics['rejectedByRaster'], 0);
    final tail = renderer.scrollDanmaku.single.single;
    renderer.advance(
      Duration(
        milliseconds: ((tail.width + 1) * 2000 / (_size.width + tail.width))
            .ceil(),
      ),
    );
    expect(renderer.add(_text('burst')), isTrue);
    expect(renderer.statistics['rejectedByTrack'], 1);
  });

  test('eviction pressure reasons differ from payload counts and clones keep pixels', () async {
    final a = _text('same');
    final b = DanmakuContentItem<void>('same', color: const Color(0xFFFF0000));
    final layoutOnly = DanmakuContentItem<void>(
      'same',
      color: const Color(0xFF00FF00),
    );
    final probe = DanmakuRasterCache(option: _option, devicePixelRatio: 1);
    final itemBytes = probe.get(a)!.bytes;
    probe.clear();
    final cache = DanmakuRasterCache(
      option: _option,
      devicePixelRatio: 1,
      maxEntries: 2,
      maxBytes: itemBytes,
    );
    addTearDown(cache.clear);
    cache.get(layoutOnly);
    final original = cache.get(a, rasterize: true)!.image!;
    final clone = original.clone();
    addTearDown(clone.dispose);
    final before = await clone.toByteData(format: ui.ImageByteFormat.rawRgba);
    cache.get(b, rasterize: true);
    expect(cache.evictions, 2);
    expect(cache.evictionsByBytes, 2);
    expect(cache.evictionsByEntries, 1);
    expect(cache.evictedLayouts, 1);
    expect(cache.evictedImages, 1);
    expect(cache.evictedImageBytes, itemBytes);
    expect(cache.bytes, itemBytes);
    final after = await clone.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(after!.buffer.asUint8List(), before!.buffer.asUint8List());
    cache.clear();
    expect(cache.bytes, 0);
    expect(cache.evictions, 2);
    expect(cache.evictedImages, 1);
    final afterClear = await clone.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    expect(afterClear!.buffer.asUint8List(), before.buffer.asUint8List());
  });

  test(
    'rejected layouts can evict images without invalidating active pixels',
    () async {
      final renderer = WindowsDanmakuRenderer<void>(
        option: _option.copyWith(area: 0.3, safeArea: false),
        size: _size,
        rasterCacheMaxEntries: 1,
      );
      addTearDown(renderer.dispose);
      final a = _text('same', type: DanmakuItemType.top);
      final b = DanmakuContentItem<void>(
        'same',
        color: const Color(0xFFFF0000),
        type: DanmakuItemType.top,
      );
      expect(renderer.add(a), isTrue);
      final active = renderer.staticDanmaku.single!.image!;
      final before = await active.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      final activeBytes = renderer.activeBytes;
      expect(renderer.add(b), isFalse);
      expect(renderer.rejectedByTrack, 1);
      expect(renderer.rasters.isRasterized(a), isFalse);
      expect(renderer.rasters.rasterizations, 1);
      expect(renderer.statistics['evictedImages'], 1);
      expect(renderer.statistics['evictedLayouts'], 0);
      expect(renderer.rasters.bytes, 0);
      expect(renderer.activeBytes, activeBytes);
      final after = await active.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(after!.buffer.asUint8List(), before!.buffer.asUint8List());
    },
  );

  test('standalone rasterization of an old layout can evict its own image', () {
    final a = _text('same');
    final b = DanmakuContentItem<void>('same', color: const Color(0xFFFF0000));
    final probe = DanmakuRasterCache(option: _option, devicePixelRatio: 1);
    final itemBytes = probe.get(a)!.bytes;
    probe.clear();
    final cache = DanmakuRasterCache(
      option: _option,
      devicePixelRatio: 1,
      maxEntries: 2,
      maxBytes: itemBytes,
    );
    addTearDown(cache.clear);
    final old = cache.get(a)!;
    cache.get(b, rasterize: true);
    expect(cache.rasterize(a, old), isNull);
    expect(cache.isRasterized(b), isTrue);
    expect(cache.evictions, 1);
    expect(cache.evictedImages, 1);
    expect(cache.evictedLayouts, 0);
    expect(cache.bytes, itemBytes);
  });
}
