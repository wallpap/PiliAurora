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
}
