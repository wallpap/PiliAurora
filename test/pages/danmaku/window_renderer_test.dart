import 'dart:ui' as ui;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';

import '../../../tool/experiments/danmaku/baseline/windows_renderer.dart';

const _size = Size(320, 120);
const _option = DanmakuOption(fontSize: 20, duration: 2, safeArea: false);
DanmakuContentItem<void> _text(String text) =>
    DanmakuContentItem(text, color: const Color(0xffffffff));

Future<List<int>> _pixels(
  DanmakuWindowRenderer<void> renderer, {
  double opacity = 1,
}) => _draw((canvas) => renderer.paint(canvas, _size, opacity: opacity));

Future<List<int>> _draw(void Function(Canvas) paint) async {
  final recorder = ui.PictureRecorder();
  paint(Canvas(recorder));
  final picture = recorder.endRecording();
  final image = await picture.toImage(320, 120);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final result = data!.buffer.asUint8List().toList();
  image.dispose();
  picture.dispose();
  return result;
}

SpecialDanmakuContentItem<void> _special({
  int duration = 2000,
  double fontSize = 20,
}) => SpecialDanmakuContentItem<void>(
  'special',
  duration: duration,
  color: const Color(0xffffffff),
  fontSize: fontSize,
  alphaTween: Tween<double>(begin: .2, end: .8),
  translateXTween: Tween<double>(begin: .1, end: .6),
  translateYTween: ConstantTween<double>(.25),
  rotateZ: .2,
  translationStartDelay: 400,
  translationDuration: 1000,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'duplicate identities in a batch measure and retain the first content',
    () {
      final renderer = DanmakuWindowRenderer<void>(
        option: _option,
        size: _size,
      );
      addTearDown(renderer.dispose);
      renderer.prepare(
        [
          DanmakuWindowContent('same', 0, _text('first')),
          DanmakuWindowContent('same', 0, _text('second text')),
        ],
        generation: renderer.generation,
        preparedUntilUs: 1000000,
      );
      renderer.present(0);
      expect(renderer.interaction.snapshot.single.text, 'first');
      expect(renderer.rasters.length, 1);
    },
  );

  test('simultaneous raster pressure activates higher weights first', () {
    final measure = DanmakuWindowRenderer<void>(option: _option, size: _size);
    final bytes = measure.rasters.get(_text('bbbb'))!.bytes;
    measure.dispose();
    final renderer = DanmakuWindowRenderer<void>(
      option: _option.copyWith(massiveMode: true),
      size: _size,
      maxActiveBytes: bytes,
    );
    addTearDown(renderer.dispose);
    renderer.prepare(
      [
        DanmakuWindowContent('low', 0, _text('aaaa'), weight: 1),
        DanmakuWindowContent('high', 0, _text('bbbb'), weight: 10),
      ],
      generation: renderer.generation,
      preparedUntilUs: 2000000,
    );
    renderer.present(0);
    expect(renderer.interaction.snapshot.map((e) => e.identity), ['high']);
  });

  test('new raster pressure preserves current visible image references', () {
    final renderer = DanmakuWindowRenderer<void>(
      option: _option,
      size: _size,
      maxWorkingSetBytes: 24 * 1024,
    );
    addTearDown(renderer.dispose);
    renderer
      ..prepare(
        [DanmakuWindowContent('keep', 0, _text('keep'))],
        generation: renderer.generation,
        preparedUntilUs: 3000000,
      )
      ..present(500000);
    final handle = renderer.interaction;
    final bounds = handle.snapshot.single.bounds;
    final bytes = renderer.activeBytes;
    renderer
      ..prepare(
        [DanmakuWindowContent('large', 0, _text('oversized current raster'))],
        generation: renderer.generation,
        preparedUntilUs: 3000000,
      )
      ..present(500000);
    expect(handle.snapshot.single.identity, 'keep');
    expect(handle.snapshot.single.bounds, bounds);
    expect(renderer.activeBytes, bytes);
    expect(
      renderer.workingSetBytes,
      lessThanOrEqualTo(renderer.maxWorkingSetBytes),
    );
  });

  test(
    'a full window reclaims expired decisions and keeps active trajectories',
    () {
      final renderer = DanmakuWindowRenderer<void>(
        option: _option.copyWith(hideTop: true),
        size: _size,
      );
      addTearDown(renderer.dispose);
      renderer.prepare(
        [DanmakuWindowContent('keep', 0, _text('keep'))],
        generation: renderer.generation,
        preparedUntilUs: 100000,
      );
      for (var i = 0; i < 3071; i += 120) {
        renderer.prepare(
          [
            for (var j = i; j < i + 120 && j < 3071; j++)
              DanmakuWindowContent(
                j,
                j + 1,
                DanmakuContentItem<void>('hidden', type: DanmakuItemType.top),
              ),
          ],
          generation: renderer.generation,
          preparedUntilUs: 100000,
        );
      }
      renderer.present(50000);
      final before = renderer.interaction.snapshot.single.bounds;
      expect(
        renderer.prepare(
          [DanmakuWindowContent('new', 100000, _text('new'))],
          generation: renderer.generation,
          preparedUntilUs: 200000,
        ),
        isTrue,
      );
      expect(renderer.hasPrepared(0), isFalse);
      expect(renderer.validFromUs, 50000);
      renderer.present(50000);
      expect(renderer.interaction.snapshot.single.bounds, before);
      expect(renderer.interaction.snapshot.single.identity, 'keep');
    },
  );

  test('admission pressure reclaims expired source history while retaining visible resources', () {
    final renderer = DanmakuWindowRenderer<void>(
      option: _option.copyWith(massiveMode: true),
      size: _size,
      maxWorkingSetBytes: 96 * 1024,
    );
    addTearDown(renderer.dispose);
    DanmakuWindowContent<void> emote(String id, int sourceUs) {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xffff0000), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(128, 128);
      picture.dispose();
      final content = DanmakuContentItem<void>(
        '[e]',
        inlineImages: [
          DanmakuInlineImage(
            placeholder: '[e]',
            image: image,
            width: 16,
            height: 16,
          ),
        ],
      );
      addTearDown(content.dispose);
      return DanmakuWindowContent(id, sourceUs, content);
    }

    renderer
      ..prepare(
        [emote('expired', 0)],
        generation: renderer.generation,
        preparedUntilUs: 10000000,
      )
      ..present(500000)
      ..prepare(
        [DanmakuWindowContent('visible', 1500000, _text('visible'))],
        generation: renderer.generation,
        preparedUntilUs: 10000000,
      )
      ..present(2500000);
    final before = renderer.interaction.snapshot.single.bounds;
    final handle = renderer.interaction;
    expect(renderer.workingSetBytes, greaterThanOrEqualTo(128 * 128 * 4));
    expect(
      renderer.prepare(
        [emote('new', 2500000)],
        generation: renderer.generation,
        preparedUntilUs: 10000000,
      ),
      isTrue,
    );
    renderer.present(2500000);
    expect(renderer.hasPrepared('expired'), isFalse);
    expect(renderer.validFromUs, 2500000);
    expect(
      handle.snapshot.firstWhere((item) => item.identity == 'visible').bounds,
      before,
    );
    expect(handle.isValid, isTrue);
    expect(renderer.activeCount, 2);
    expect(
      renderer.workingSetBytes,
      lessThanOrEqualTo(renderer.maxWorkingSetBytes),
    );
  });

  test('independent emote sources are budgeted before layout and survive caller release', () {
    final renderer = DanmakuWindowRenderer<void>(
      option: _option.copyWith(massiveMode: true),
      size: _size,
      maxWorkingSetBytes: 96 * 1024,
    );
    addTearDown(renderer.dispose);
    DanmakuContentItem<void> content() {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xffff0000), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(128, 128);
      picture.dispose();
      return DanmakuContentItem<void>(
        '[e]',
        inlineImages: [
          DanmakuInlineImage(
            placeholder: '[e]',
            image: image,
            width: 16,
            height: 16,
          ),
        ],
      );
    }

    final first = content();
    expect(
      renderer.prepare(
        [DanmakuWindowContent('first', 0, first)],
        generation: renderer.generation,
        preparedUntilUs: 3000000,
      ),
      isTrue,
    );
    renderer.present(500000);
    first.dispose();
    expect(renderer.activeCount, 1);
    expect(renderer.workingSetBytes, greaterThanOrEqualTo(128 * 128 * 4));
    final before = renderer.rasters.layouts;
    final second = content();
    expect(
      renderer.prepare(
        [DanmakuWindowContent('second', 0, second)],
        generation: renderer.generation,
        preparedUntilUs: 3000000,
      ),
      isFalse,
    );
    second.dispose();
    expect(renderer.rasters.layouts, before);
    expect(
      renderer.workingSetBytes,
      lessThanOrEqualTo(renderer.maxWorkingSetBytes),
    );
    expect(renderer.statistics['active'], 1);
    renderer.requestConfiguration(
      option: renderer.rasters.option.copyWith(fontSize: 24),
      size: _size,
      devicePixelRatio: 1,
    );
    expect(renderer.prepareConfiguration(), isTrue);
    renderer.present(500000, allowUnprepared: true);
    expect(renderer.activeCount, 1);
    renderer.present(3000000, allowUnprepared: true);
    renderer.prepare(
      [],
      generation: renderer.generation,
      preparedUntilUs: 3000001,
    );
    renderer.trimBefore(3000000);
    expect(renderer.statistics['active'], 0);
    expect(renderer.workingSetBytes, lessThan(128 * 128 * 4));
  });

  test(
    'rejected emote content can be disposed before statistics and expiry',
    () {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xffff0000), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(8, 8);
      picture.dispose();
      final item = DanmakuContentItem<void>(
        '[e]',
        inlineImages: [
          DanmakuInlineImage(
            placeholder: '[e]',
            image: image,
            width: 16,
            height: 16,
          ),
        ],
      );
      final renderer = DanmakuWindowRenderer<void>(
        option: _option,
        size: _size,
        maxActiveBytes: 1,
      );
      addTearDown(renderer.dispose);
      renderer
        ..prepare(
          [DanmakuWindowContent('rejected', 0, item)],
          generation: renderer.generation,
          preparedUntilUs: 3000000,
        )
        ..present(500000);
      expect(renderer.activeCount, 0);
      item.dispose();
      expect(renderer.statistics['active'], 0);
      renderer
        ..present(3000000)
        ..trimBefore(3000000);
      expect(renderer.statistics['active'], 0);
      renderer.reset(3000000);
      expect(renderer.workingSetBytes, lessThan(renderer.maxWorkingSetBytes));
    },
  );

  for (final ratio in [1.0, 2.0]) {
    for (final special in [false, true]) {
      test(
        'opacity and overlap match baseline at DPR $ratio, special=$special',
        () async {
          final option = _option.copyWith(massiveMode: true);
          final old = WindowsDanmakuRenderer<void>(
            option: option,
            size: _size,
            devicePixelRatio: ratio,
          );
          final next = DanmakuWindowRenderer<void>(
            option: option,
            size: _size,
            devicePixelRatio: ratio,
          );
          addTearDown(old.dispose);
          addTearDown(next.dispose);
          DanmakuContentItem<void> content() =>
              special ? _special() : _text('overlap');
          final inputs = [for (var i = 0; i < 12; i++) content()];
          for (final item in inputs) {
            expect(old.add(item), isTrue);
          }
          old.advance(const Duration(milliseconds: 500));
          next
            ..prepare(
              [
                for (var i = 0; i < inputs.length; i++)
                  DanmakuWindowContent(i, 0, inputs[i]),
              ],
              generation: next.generation,
              preparedUntilUs: 3000000,
            )
            ..present(500000);
          expect(next.activeCount, inputs.length);
          for (final opacity in [0.0, .25, .5, 1.0]) {
            expect(
              await _pixels(next, opacity: opacity),
              await _draw(
                (canvas) => old.paint(canvas, _size, opacity: opacity),
              ),
              reason: 'opacity=$opacity',
            );
          }
          expect(next.groupPaints, 2);
          expect(next.directPaints, 1);
        },
      );
    }
  }

  test(
    'inline emote burst shares backing and paint keeps resources unchanged',
    () async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xffff0000), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final emote = picture.toImageSync(16, 16);
      picture.dispose();
      addTearDown(emote.dispose);
      final renderer = DanmakuWindowRenderer<void>(
        option: _option.copyWith(massiveMode: true),
        size: _size,
        devicePixelRatio: 2,
        rasterCacheMaxBytes: 128 * 1024,
        maxActiveBytes: 128 * 1024,
        maxWorkingSetBytes: 1024 * 1024,
      );
      addTearDown(renderer.dispose);
      DanmakuContentItem<void> content() => DanmakuContentItem<void>(
        '[e]',
        inlineImages: [
          DanmakuInlineImage(
            placeholder: '[e]',
            image: emote.clone(),
            width: 16,
            height: 16,
          ),
        ],
      );
      final inputs = [
        for (var i = 0; i < 120; i++) DanmakuWindowContent(i, 0, content()),
      ];
      renderer
        ..prepare(
          inputs,
          generation: renderer.generation,
          preparedUntilUs: 3000000,
        )
        ..present(500000);
      for (final input in inputs) {
        input.content.dispose();
      }
      expect(renderer.activeCount, 120);
      expect(renderer.rasters.rasterizations, 1);
      expect(renderer.rasters.length, 1);
      expect(renderer.activeBytes, renderer.rasters.bytes);
      expect(
        renderer.workingSetBytes,
        lessThanOrEqualTo(renderer.maxWorkingSetBytes),
      );
      final layouts = renderer.rasters.layouts;
      final bytes = renderer.workingSetBytes;
      final pixels = await _pixels(renderer, opacity: .5);
      expect(pixels.any((byte) => byte != 0), isTrue);
      expect(await _pixels(renderer, opacity: .5), pixels);
      expect(renderer.rasters.layouts, layouts);
      expect(renderer.rasters.rasterizations, 1);
      expect(renderer.workingSetBytes, bytes);
      renderer.rasters.clear();
      expect(await _pixels(renderer, opacity: .5), pixels);
      renderer.reset(3000000);
      expect(renderer.activeBytes, 0);
      expect(emote.debugDisposed, isFalse);
    },
  );

  for (final ratio in [1.0, 2.0]) {
    test(
      'special script pixels match existing renderer at DPR $ratio',
      () async {
        final old = WindowsDanmakuRenderer<void>(
          option: _option,
          size: _size,
          devicePixelRatio: ratio,
        );
        final next = DanmakuWindowRenderer<void>(
          option: _option,
          size: _size,
          devicePixelRatio: ratio,
        );
        addTearDown(old.dispose);
        addTearDown(next.dispose);
        old
          ..add(_special())
          ..advance(const Duration(milliseconds: 500));
        next
          ..prepare(
            [DanmakuWindowContent('special', 1000000, _special())],
            generation: next.generation,
            preparedUntilUs: 4000000,
          )
          ..present(1500000);
        expect(next.activeSpecialCount, 1);
        expect(
          await _pixels(next),
          await _draw((canvas) => old.paint(canvas, _size)),
        );
        final bytes = next.activeBytes;
        next.present(1500000);
        expect(next.activeBytes, bytes);
        next.present(3000000);
        expect(next.activeBytes, 0);
      },
    );
  }

  test('special quota follows exact lifetimes and future entries do not occupy slots', () {
    final renderer = DanmakuWindowRenderer<void>(option: _option, size: _size);
    addTearDown(renderer.dispose);
    renderer
      ..prepare(
        [
          for (var index = 0; index < 33; index++)
            DanmakuWindowContent(index, 0, _special(duration: 10000)),
          DanmakuWindowContent('future', 10000000, _special(duration: 10000)),
        ],
        generation: renderer.generation,
        preparedUntilUs: 20000000,
      )
      ..present(9994000);
    expect(renderer.activeSpecialCount, 32);
    renderer.present(9999000);
    expect(renderer.activeSpecialCount, 32);
    renderer.present(10000000);
    expect(renderer.activeSpecialCount, 1);
    renderer.present(20000000);
    expect(renderer.activeBytes, 0);
  });

  test('special resource budget and invalid script measurements reject without active references', () {
    final renderer = DanmakuWindowRenderer<void>(
      option: _option,
      size: _size,
      maxActiveBytes: 1,
    );
    addTearDown(renderer.dispose);
    renderer
      ..prepare(
        [
          DanmakuWindowContent(
            'invalid',
            0,
            _special(fontSize: double.infinity),
          ),
          DanmakuWindowContent('budget', 0, _special()),
        ],
        generation: renderer.generation,
        preparedUntilUs: 3000000,
      )
      ..present(500000);
    expect(renderer.activeSpecialCount, 0);
    expect(renderer.activeBytes, 0);
  });

  for (final ratio in [1.0, 2.0]) {
    test('window pixels match the existing renderer at DPR $ratio', () async {
      final current = WindowsDanmakuRenderer<void>(
        option: _option,
        size: _size,
        devicePixelRatio: ratio,
      );
      final next = DanmakuWindowRenderer<void>(
        option: _option,
        size: _size,
        devicePixelRatio: ratio,
      );
      addTearDown(current.dispose);
      addTearDown(next.dispose);
      current
        ..add(_text('same pixels'))
        ..advance(const Duration(milliseconds: 500));
      next
        ..prepare(
          [DanmakuWindowContent('a', 0, _text('same pixels'))],
          generation: next.generation,
          preparedUntilUs: 3000000,
        )
        ..present(500000);
      for (final opacity in [.25, .5, 1.0]) {
        expect(
          await _pixels(next, opacity: opacity),
          await _draw(
            (canvas) => current.paint(canvas, _size, opacity: opacity),
          ),
        );
      }
      expect(next.groupPaints, 0);
    });
  }

  test(
    'prepare measures ahead; media-time presentation and hit geometry agree',
    () async {
      final renderer = DanmakuWindowRenderer<void>(
        option: _option,
        size: _size,
      );
      addTearDown(renderer.dispose);
      final content = _text('window item');
      expect(
        renderer.prepare(
          [
            DanmakuWindowContent('first', 0, content),
            DanmakuWindowContent('future', 1000000, _text('future')),
          ],
          generation: renderer.generation,
          preparedUntilUs: 4000000,
        ),
        isTrue,
      );
      expect(renderer.activeCount, 0);
      expect(renderer.rasters.rasterizations, 0);
      final layout = renderer.rasters.get(content)!;
      renderer.present(500000);
      final x = 320 - (320 + layout.width) / 2000 * 500;
      final hit = renderer.hitTest(
        Offset(x + layout.width / 2, layout.height / 2),
      );
      expect(hit!.identity, 'first');
      expect(hit.bounds.left, closeTo(x, 0.001));
      final before = await _pixels(renderer);
      expect(before.any((byte) => byte != 0), isTrue);
      final rasterizations = renderer.rasters.rasterizations;
      renderer.present(500000);
      expect(await _pixels(renderer), before);
      expect(renderer.rasters.rasterizations, rasterizations);
    },
  );

  test(
    'expiry releases active clones; cached backseek restores identical pixels',
    () async {
      final renderer = DanmakuWindowRenderer<void>(
        option: _option,
        size: _size,
      );
      addTearDown(renderer.dispose);
      renderer
        ..prepare(
          [DanmakuWindowContent('a', 0, _text('cached'))],
          generation: renderer.generation,
          preparedUntilUs: 4000000,
        )
        ..present(600000);
      final expected = await _pixels(renderer);
      expect(renderer.activeBytes, greaterThan(0));
      final images = renderer.rasters.rasterizations;
      renderer.present(3000000);
      expect(renderer.activeCount, 0);
      expect(renderer.activeBytes, 0);
      renderer.present(600000);
      expect(await _pixels(renderer), expected);
      expect(renderer.rasters.rasterizations, images);
      renderer.trimBefore(1000000);
      expect(renderer.present(600000), isFalse);
      expect(renderer.activeBytes, 0);
    },
  );

  test(
    'active raster budget and reset generation prevent invalid presentation',
    () {
      final renderer = DanmakuWindowRenderer<void>(
        option: _option,
        size: _size,
        maxActiveBytes: 1,
      );
      addTearDown(renderer.dispose);
      final generation = renderer.generation;
      renderer
        ..prepare(
          [DanmakuWindowContent('a', 0, _text('budget'))],
          generation: generation,
          preparedUntilUs: 4000000,
        )
        ..present(100000);
      expect(renderer.activeBytes, 0);
      expect(renderer.rasters.rasterizations, 0);
      renderer.reset(800000);
      expect(
        renderer.prepare(
          [DanmakuWindowContent('stale', 900000, _text('stale'))],
          generation: generation,
          preparedUntilUs: 4000000,
        ),
        isFalse,
      );
      expect(renderer.validFromUs, 800000);
      expect(renderer.validUntilUs, 800000);
      expect(renderer.hitTest(Offset.zero), isNull);
    },
  );

  test(
    'nonoverlapping opacity paints directly with unchanged frame alpha',
    () async {
      final renderer = DanmakuWindowRenderer<void>(
        option: _option,
        size: _size,
      );
      addTearDown(renderer.dispose);
      renderer
        ..prepare(
          [DanmakuWindowContent('a', 0, _text('opacity'))],
          generation: renderer.generation,
          preparedUntilUs: 3000000,
        )
        ..present(500000);
      final full = await _pixels(renderer);
      final half = await _pixels(renderer, opacity: 0.5);
      var fullAlpha = 0;
      var halfAlpha = 0;
      for (var i = 3; i < full.length; i += 4) {
        if (full[i] > fullAlpha) fullAlpha = full[i];
        if (half[i] > halfAlpha) halfAlpha = half[i];
      }
      expect(fullAlpha, greaterThan(0));
      expect(halfAlpha, closeTo(fullAlpha / 2, 1));
      expect(renderer.groupPaints, 0);
      expect(renderer.directPaints, 2);
    },
  );
}
