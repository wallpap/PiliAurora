import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/pages/danmaku/window_screen.dart';
import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';

class _Clock implements PlaybackMediaClock {
  _Clock(this.currentMediaAnchor);
  @override
  PlaybackMediaAnchor? currentMediaAnchor;
  final events = StreamController<PlaybackMediaAnchor?>.broadcast(sync: true);
  @override
  Stream<PlaybackMediaAnchor?> get mediaAnchors => events.stream;
  void emit(PlaybackMediaAnchor? anchor) {
    currentMediaAnchor = anchor;
    events.add(anchor);
  }
}

PlaybackMediaAnchor _anchor({
  int position = 0,
  int observed = 0,
  int continuity = 0,
  bool advancing = true,
  int validFor = 10000000,
  double rate = 1,
}) => PlaybackMediaAnchor(
  positionUs: position,
  observedAtUs: observed,
  effectiveRate: rate,
  advancing: advancing,
  ready: true,
  continuity: continuity,
  validForUs: validFor,
);

Widget _host(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: const MediaQueryData(size: Size(320, 120)),
    child: Center(child: SizedBox(width: 320, height: 120, child: child)),
  ),
);

Future<void> _mount(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(child);
  await tester.pump();
}

DanmakuWindowRenderer<void> _renderer() => DanmakuWindowRenderer(
  option: const DanmakuOption(fontSize: 20, duration: 8, safeArea: false),
  size: const Size(320, 120),
);

void _prepare(DanmakuWindowRenderer<void> renderer, int position) {
  if (renderer.validUntilUs != renderer.validFromUs) return;
  renderer.prepare(
    [
      DanmakuWindowContent(
        'a',
        renderer.validFromUs,
        DanmakuContentItem<void>('clock', color: const Color(0xffffffff)),
      ),
    ],
    generation: renderer.generation,
    preparedUntilUs: renderer.validFromUs + 10000000,
  );
}

void _prepareMixed(DanmakuWindowRenderer<void> renderer, int position) {
  if (renderer.validUntilUs != renderer.validFromUs) return;
  renderer.prepare(
    [
      DanmakuWindowContent('a', 0, DanmakuContentItem<void>('scroll')),
      for (final at in [0, 500000]) ...[
        DanmakuWindowContent(
          'top-$at',
          at,
          DanmakuContentItem<void>('top', type: DanmakuItemType.top),
        ),
        DanmakuWindowContent(
          'bottom-$at',
          at,
          DanmakuContentItem<void>('bottom', type: DanmakuItemType.bottom),
        ),
      ],
    ],
    generation: renderer.generation,
    preparedUntilUs: 10000000,
  );
}

void main() {
  for (final lead in [-6000, 0, 12000]) {
    for (final settleFrame in [false, true]) {
      testWidgets('长按松手的短暂状态交接保留已呈现位置 $lead/$settleFrame', (tester) async {
        var now = 0;
        final clock = _Clock(_anchor(position: 1000000, rate: 2));
        final renderer = _renderer();
        addTearDown(renderer.dispose);
        addTearDown(clock.events.close);
        await _mount(
          tester,
          _host(
            DanmakuWindowScreen<void>(
              renderer: renderer,
              clock: clock,
              size: const Size(320, 120),
              monotonicUs: () => now,
              frameTimeUs: () => now + lead,
              prepareFrame: (r, p, {required effectiveRate}) => _prepare(r, p),
            ),
          ),
        );
        for (var frame = 0; frame < 15; frame++) {
          now += 16667;
          await tester.pump(const Duration(microseconds: 16667));
        }
        if (settleFrame) {
          clock.emit(
            _anchor(
              position: renderer.presentationTimeUs + 80000,
              observed: now,
            ),
          );
          now += 16667;
          await tester.pump(const Duration(microseconds: 16667));
        }
        final before = renderer.presentationTimeUs;
        final bounds = renderer.interaction.snapshot.single.bounds;
        // 松手时保留原生位置与已校准呈现之间的相位差，交接中短暂停止推进。
        clock.emit(
          _anchor(
            position: before + 80000,
            observed: now,
            rate: settleFrame ? 1 : 2,
            advancing: false,
          ),
        );
        expect(renderer.presentationTimeUs, before);
        expect(renderer.interaction.snapshot.single.bounds, bounds);
        now += 60000;
        await tester.pump(const Duration(microseconds: 60000));
        expect(renderer.presentationTimeUs, before);
        clock.emit(_anchor(position: before + 80000, observed: now));
        expect(renderer.presentationTimeUs, before);
        now += 16667;
        await tester.pump(const Duration(microseconds: 16667));
        expect(
          renderer.presentationTimeUs - before,
          inInclusiveRange(15800, 17550),
        );
        clock.emit(_anchor(position: 100000, continuity: 1, advancing: false));
        await tester.pump();
        expect(renderer.presentationTimeUs, 100000);
        await _mount(tester, const SizedBox.shrink());
      });
    }
  }

  testWidgets('长按松手的显示空档不叠加原生校准位移', (tester) async {
    var now = 0;
    final clock = _Clock(_anchor(position: 1000000, rate: 2));
    final renderer = _renderer();
    addTearDown(renderer.dispose);
    addTearDown(clock.events.close);
    await _mount(
      tester,
      _host(
        DanmakuWindowScreen<void>(
          renderer: renderer,
          clock: clock,
          size: const Size(320, 120),
          monotonicUs: () => now,
          frameTimeUs: () => now,
          prepareFrame: (r, p, {required effectiveRate}) => _prepare(r, p),
        ),
      ),
    );
    now += 16667;
    await tester.pump(const Duration(microseconds: 16667));
    final before = renderer.presentationTimeUs;
    clock.emit(_anchor(position: before + 80000, observed: now));
    now += 100000;
    await tester.pump(const Duration(microseconds: 100000));
    expect(
      renderer.presentationTimeUs - before,
      inInclusiveRange(94000, 106000),
    );
    await _mount(tester, const SizedBox.shrink());
  });

  for (final rates in [
    [1.0, 2.0],
    [2.0, 1.0],
    [3.0, .5],
    [.5, 2.0, .5, 2.0, .5],
  ]) {
    testWidgets('倍速切换 ${rates.join(' → ')} 保留逐帧运动', (tester) async {
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      var now = 0;
      final clock = _Clock(_anchor(rate: rates.first));
      final renderer = _renderer();
      addTearDown(renderer.dispose);
      addTearDown(clock.events.close);
      await _mount(
        tester,
        _host(
          DanmakuWindowScreen<void>(
            renderer: renderer,
            clock: clock,
            size: const Size(320, 120),
            monotonicUs: () => now,
            frameTimeUs: () => now,
            prepareFrame: (r, p, {required effectiveRate}) => _prepare(r, p),
          ),
        ),
      );
      for (var frame = 0; frame < 30; frame++) {
        now += 8333;
        await tester.pump(const Duration(microseconds: 8333));
      }
      final generation = renderer.generation;
      for (var change = 1; change < rates.length; change++) {
        final before = rates[change - 1];
        final after = rates[change];
        final atSwitch = renderer.presentationTimeUs;
        // 切速后的 time-pos 仍可能落在上一视频帧；保留旧速率下 40ms 的采样差。
        final sampled = atSwitch - (40000 * before).round();
        final steps = <int>[];
        var previous = atSwitch;
        final frames = before == 3 ? 720 : 30;
        for (var frame = 0; frame < frames; frame++) {
          clock.emit(
            _anchor(
              position: sampled + (frame * 8333 * after).round(),
              observed: now,
              rate: after,
            ),
          );
          now += 8333;
          await tester.pump(const Duration(microseconds: 8333));
          final position = renderer.presentationTimeUs;
          steps.add(position - previous);
          previous = position;
        }
        expect(renderer.generation, generation);
        final nominal = 8333 * after;
        expect(
          steps,
          everyElement(
            inInclusiveRange((nominal * .94).floor(), (nominal * 1.06).ceil()),
          ),
          reason: '切速、长按加速和松手恢复均不应出现静止帧或位置跳变',
        );
        if (frames == 720) {
          expect(
            previous,
            closeTo(sampled + frames * 8333 * after, 1000),
            reason: '持续播放后应收敛到原生媒体时间',
          );
        }
      }
      await _mount(tester, const SizedBox.shrink());
    });
  }

  for (final videoRate in [24, 30, 60]) {
    testWidgets('$videoRate FPS 混合滚动与固定弹幕的锚点抖动不造成停顿和跳动', (
      tester,
    ) async {
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      final origin = tester.binding.clock.now().microsecondsSinceEpoch;
      var now = origin;
      final clock = _Clock(_anchor(observed: origin));
      final renderer = DanmakuWindowRenderer<void>(
        option: const DanmakuOption(
          fontSize: 20,
          duration: 8,
          staticDuration: .25,
          safeArea: false,
        ),
        size: const Size(320, 120),
      );
      addTearDown(renderer.dispose);
      addTearDown(clock.events.close);
      await _mount(
        tester,
        _host(
          DanmakuWindowScreen<void>(
            renderer: renderer,
            clock: clock,
            size: const Size(320, 120),
            monotonicUs: () => now,
            prepareFrame: (r, p, {required effectiveRate}) =>
                _prepareMixed(r, p),
          ),
        ),
      );
      final positions = <int>[];
      final lefts = <double>[];
      var fixedPeak = 0;
      var fixedExpiries = 0;
      var previousFixed = 0;
      final fixedBounds = <Object, Rect>{};
      final stride = 120 ~/ videoRate;
      for (var slot = 1; slot <= 120; slot++) {
        final sampled = slot % stride == 0;
        final delay = sampled && (slot ~/ stride).isEven ? 6000 : 1000;
        final delivered = origin + slot * 8333 + delay;
        await tester.binding.delayed(Duration(microseconds: delivered - now));
        now = delivered;
        if (sampled) {
          // time-pos 按视频帧推进；属性读取时刻包含本次通知的交付延迟。
          clock.emit(_anchor(position: slot * 8333, observed: now));
        }
        tester.binding.handleBeginFrame(
          Duration(microseconds: origin + (slot + 1) * 8333),
        );
        tester.binding.handleDrawFrame();
        positions.add(renderer.presentationTimeUs);
        final displayed = renderer.interaction.snapshot;
        lefts.add(displayed.singleWhere((s) => s.identity == 'a').bounds.left);
        final fixed = displayed.where((s) => s.identity != 'a').length;
        for (final item in displayed.where((s) => s.identity != 'a')) {
          final bounds = fixedBounds.putIfAbsent(
            item.identity,
            () => item.bounds,
          );
          expect(item.bounds, bounds);
        }
        if (fixed > fixedPeak) fixedPeak = fixed;
        if (previousFixed > 0 && fixed == 0) fixedExpiries++;
        previousFixed = fixed;
      }
      await _mount(tester, const SizedBox.shrink());
      final steps = [
        for (var i = 1; i < positions.length; i++)
          positions[i] - positions[i - 1],
      ];
      expect(steps, everyElement(inInclusiveRange(7883, 8783)));
      expect(positions.last, closeTo(121 * 8333, 10000));
      expect(fixedPeak, 2);
      expect(fixedExpiries, 2);
      expect(fixedBounds.keys.toSet(), {
        'top-0',
        'bottom-0',
        'top-500000',
        'bottom-500000',
      });
      final nominalStep = (lefts.first - lefts.last) / (lefts.length - 1);
      for (var i = 1; i < lefts.length; i++) {
        expect(
          lefts[i - 1] - lefts[i],
          closeTo(nominalStep, nominalStep * .1),
        );
      }
    });
  }

  testWidgets('回调交付抖动不改变跟随屏幕时的逐帧位移', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final origin = tester.binding.clock.now().microsecondsSinceEpoch;
    var now = origin;
    final clock = _Clock(_anchor(observed: origin));
    final renderer = _renderer();
    addTearDown(renderer.dispose);
    addTearDown(clock.events.close);
    await _mount(
      tester,
      _host(
        DanmakuWindowScreen<void>(
          renderer: renderer,
          clock: clock,
          size: const Size(320, 120),
          monotonicUs: () => now,
          prepareFrame: (r, p, {required effectiveRate}) => _prepare(r, p),
        ),
      ),
    );
    final positions = <int>[];
    final lefts = <double>[];
    for (var slot = 1; slot <= 30; slot++) {
      final delivered = origin + slot * 8333 + (slot.isEven ? 6000 : 1000);
      await tester.binding.delayed(Duration(microseconds: delivered - now));
      now = delivered;
      clock.emit(_anchor(position: now - origin, observed: now));
      tester.binding.handleBeginFrame(
        Duration(microseconds: origin + (slot + 1) * 8333),
      );
      tester.binding.handleDrawFrame();
      positions.add(renderer.presentationTimeUs);
      lefts.add(renderer.interaction.snapshot.single.bounds.left);
    }
    await _mount(tester, const SizedBox.shrink());
    final gaps = [
      for (var i = 1; i < positions.length; i++)
        positions[i] - positions[i - 1],
    ];
    expect(gaps, everyElement(8333));
    final step = lefts[0] - lefts[1];
    expect(step, greaterThan(0));
    for (var i = 2; i < lefts.length; i++) {
      expect(lefts[i - 1] - lefts[i], closeTo(step, .0001));
    }
  });

  testWidgets('parent rebuilds preserve scrolling time and frame cadence', (
    tester,
  ) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    var now = 0;
    final clock = _Clock(_anchor());
    final renderer = _renderer();
    addTearDown(renderer.dispose);
    addTearDown(clock.events.close);
    Widget screen() => _host(
      DanmakuWindowScreen<void>(
        renderer: renderer,
        clock: clock,
        size: const Size(320, 120),
        frameRate: 30,
        monotonicUs: () => now,
        frameTimeUs: () => now,
        prepareFrame: (r, p, {required effectiveRate}) => _prepare(r, p),
      ),
    );
    await _mount(tester, screen());
    final positions = <int>{};
    for (var slot = 1; slot <= 120; slot++) {
      final next = (slot * 1000000 / 120).round();
      await tester.binding.delayed(Duration(microseconds: next - now));
      now = next;
      await _mount(tester, screen());
      positions.add(renderer.presentationTimeUs);
    }
    expect(positions.length, inInclusiveRange(29, 31));
    await _mount(tester, const SizedBox.shrink());
  });

  // 每个目标覆盖 120/165 Hz 与稠密/稀疏采样，避免重复全交叉。
  for (final (refreshRate, sampleStride, target) in [
    (120, 1, 30),
    (120, 5, 60),
    (120, 1, 90),
    (165, 5, 30),
    (165, 1, 60),
    (165, 5, 90),
  ]) {
    testWidgets(
      '$sampleStride-slot clock samples respect $target FPS presentation and gaps on $refreshRate Hz',
      (
        tester,
      ) async {
        tester.view.display.refreshRate = refreshRate.toDouble();
        addTearDown(tester.view.display.resetRefreshRate);
        var now = 0;
        final clock = _Clock(_anchor());
        final renderer = _renderer();
        final inputs = StreamController<Object?>.broadcast(sync: true);
        addTearDown(renderer.dispose);
        addTearDown(clock.events.close);
        addTearDown(inputs.close);
        await _mount(
          tester,
          _host(
            DanmakuWindowScreen<void>(
              renderer: renderer,
              clock: clock,
              size: const Size(320, 120),
              frameRate: target,
              inputChanges: inputs.stream,
              monotonicUs: () => now,
              frameTimeUs: () => now,
              prepareFrame: (r, p, {required effectiveRate}) => _prepare(r, p),
            ),
          ),
        );
        final positions = <int>{};
        final moves = <int>[];
        var previous = renderer.presentationTimeUs;
        final initial = renderer.interaction.snapshot.single.bounds;
        for (var slot = 1; slot <= refreshRate; slot++) {
          final next = (slot * 1000000 / refreshRate).round();
          await tester.binding.delayed(Duration(microseconds: next - now));
          now = next;
          if (slot % sampleStride == 0) {
            clock.emit(_anchor(position: now, observed: now));
          }
          if (slot % 7 == 0) {
            for (var i = 0; i < 3; i++) {
              inputs.add(null);
            }
          }
          tester.binding.scheduleFrame();
          await tester.pump();
          positions.add(renderer.presentationTimeUs);
          expect(
            renderer.interaction.snapshot.single.bounds.left,
            closeTo(
              initial.left -
                  (320 + initial.width) * renderer.presentationTimeUs / 8000000,
              0.0001,
            ),
          );
          if (renderer.presentationTimeUs != previous) moves.add(now);
          previous = renderer.presentationTimeUs;
        }
        expect(positions.length, inInclusiveRange(target - 1, target + 1));
        for (var i = 1; i < moves.length; i++) {
          expect(
            moves[i] - moves[i - 1],
            inInclusiveRange(
              (refreshRate / target).floor() * 1000000 ~/ refreshRate - 1,
              ((refreshRate / target).ceil() * 1000000 / refreshRate).ceil() +
                  1,
            ),
          );
        }
        await _mount(tester, const SizedBox.shrink());
      },
    );
  }

  for (final rate in [.5, 2.0]) {
    testWidgets(
      'rate change to $rate keeps scrolling monotonic across clock corrections',
      (tester) async {
        var now = 0;
        final clock = _Clock(_anchor(validFor: 500000));
        final renderer = _renderer();
        final mediaPositions = <int>[];
        addTearDown(renderer.dispose);
        addTearDown(clock.events.close);
        await _mount(
          tester,
          _host(
            DanmakuWindowScreen<void>(
              renderer: renderer,
              clock: clock,
              size: const Size(320, 120),
              monotonicUs: () => now,
              frameTimeUs: () => now,
              prepareFrame: (r, p, {required effectiveRate}) {
                mediaPositions.add(p);
                _prepare(r, p);
              },
            ),
          ),
        );
        now = 200000;
        await tester.pump(const Duration(milliseconds: 200));
        final before = renderer.interaction.snapshot.single.bounds.left;
        final generation = renderer.generation;
        final positions = [before];
        clock.emit(
          _anchor(
            position: 180000,
            observed: now,
            rate: rate,
            validFor: 500000,
          ),
        );
        positions.add(renderer.interaction.snapshot.single.bounds.left);
        now += 100000;
        await tester.pump(const Duration(milliseconds: 100));
        positions.add(renderer.interaction.snapshot.single.bounds.left);
        clock.emit(
          _anchor(
            position: 160000 + (100000 * rate).round(),
            observed: now,
            rate: rate,
            validFor: 500000,
          ),
        );
        positions.add(renderer.interaction.snapshot.single.bounds.left);
        now += 100000;
        await tester.pump(const Duration(milliseconds: 100));
        positions.add(renderer.interaction.snapshot.single.bounds.left);
        expect(renderer.generation, generation);
        for (var index = 1; index < positions.length; index++) {
          expect(
            positions[index],
            lessThanOrEqualTo(positions[index - 1]),
            reason:
                'same-domain clock calibration must not move scrolling text right: $positions',
          );
        }
        expect(positions.last, lessThan(before));
        // 0.5 倍下按 5% 校准 35ms 相位差需要 1.4 秒，随后仍须精确贴合。
        for (var frame = 0; frame < 120; frame++) {
          now += 16667;
          clock.emit(
            _anchor(
              position: 160000 + ((now - 200000) * rate).round(),
              observed: now,
              rate: rate,
              validFor: 500000,
            ),
          );
          await tester.pump(const Duration(microseconds: 16667));
        }
        expect(mediaPositions.last, 160000 + ((now - 200000) * rate).round());
        final beforeSeek = renderer.interaction.snapshot.single.bounds.left;
        clock
          ..emit(null)
          ..emit(
            _anchor(
              position: 100000,
              observed: now,
              continuity: 1,
              rate: rate,
              advancing: false,
            ),
          );
        await tester.pump();
        expect(
          renderer.interaction.snapshot.single.bounds.left,
          greaterThan(beforeSeek),
          reason: 'a confirmed backward seek must still restore the earlier position',
        );
        await _mount(tester, const SizedBox.shrink());
      },
    );
  }

  testWidgets('same-domain clock correction keeps the latest geometry cut', (
    tester,
  ) async {
    final clock = _Clock(_anchor(position: 1000000, advancing: false));
    final renderer = _renderer();
    addTearDown(renderer.dispose);
    addTearDown(clock.events.close);
    final positions = <int>[];
    await _mount(
      tester,
      _host(
        DanmakuWindowScreen<void>(
          renderer: renderer,
          clock: clock,
          size: const Size(320, 120),
          monotonicUs: () => 0,
          frameTimeUs: () => 0,
          prepareFrame: (r, p, {required effectiveRate}) {
            positions.add(p);
            _prepare(r, p);
          },
        ),
      ),
    );
    renderer.updateTiming(
      mediaUs: 1000000,
      duration: 10,
      staticDuration: 5,
      scrollFixedVelocity: false,
    );
    final generation = renderer.generation;
    clock.emit(_anchor(position: 999000, advancing: false));
    await tester.pump();
    expect(positions.last, 1000000);
    expect(renderer.generation, generation);
    clock.emit(_anchor(position: 500000, continuity: 1, advancing: false));
    await tester.pump();
    expect(renderer.validFromUs, 500000);
    expect(renderer.generation, greaterThan(generation));
    await _mount(tester, const SizedBox.shrink());
  });

  testWidgets(
    'future static content wakes at entry and expiry without continuous frames',
    (tester) async {
      var now = 0;
      final clock = _Clock(_anchor());
      final renderer = DanmakuWindowRenderer<void>(
        option: const DanmakuOption(
          fontSize: 20,
          staticDuration: 1,
          safeArea: false,
        ),
        size: const Size(320, 120),
      );
      addTearDown(renderer.dispose);
      addTearDown(clock.events.close);
      var frames = 0;
      int? nextPreparation = 1500000;
      await _mount(
        tester,
        _host(
          DanmakuWindowScreen<void>(
            renderer: renderer,
            clock: clock,
            size: const Size(320, 120),
            monotonicUs: () => now,
            frameTimeUs: () => now,
            nextPreparationUs: () => nextPreparation,
            prepareFrame: (r, p, {required effectiveRate}) {
              frames++;
              if (p >= 1500000) nextPreparation = null;
              if (r.hasPrepared('fixed')) return;
              r.prepare(
                [
                  DanmakuWindowContent(
                    'fixed',
                    1000000,
                    DanmakuContentItem<void>(
                      'fixed',
                      type: DanmakuItemType.top,
                    ),
                  ),
                ],
                generation: r.generation,
                preparedUntilUs: 3000000,
              );
            },
          ),
        ),
      );
      expect(renderer.activeCount, 0);
      expect(tester.hasRunningAnimations, isFalse);
      final initial = frames;
      now = 200000;
      await tester.pump(const Duration(milliseconds: 200));
      expect(frames, initial);
      now = 1000000;
      await tester.pump(const Duration(milliseconds: 800));
      expect(renderer.activeCount, 1);
      expect(tester.hasRunningAnimations, isFalse);
      final afterEntry = frames;
      now = 1500000;
      await tester.pump(const Duration(milliseconds: 500));
      expect(frames, afterEntry + 1);
      expect(renderer.activeCount, 1);
      now = 2000000;
      await tester.pump(const Duration(milliseconds: 500));
      expect(renderer.activeCount, 0);
      expect(tester.hasRunningAnimations, isFalse);
      await _mount(tester, const SizedBox.shrink());
    },
  );

  testWidgets('preparation receives the observed media rate', (tester) async {
    final clock = _Clock(_anchor(rate: 2));
    final renderer = _renderer();
    addTearDown(renderer.dispose);
    addTearDown(clock.events.close);
    final rates = <double>[];
    await _mount(
      tester,
      _host(
        DanmakuWindowScreen<void>(
          renderer: renderer,
          clock: clock,
          size: const Size(320, 120),
          monotonicUs: () => 0,
          frameTimeUs: () => 0,
          prepareFrame: (r, p, {required effectiveRate}) {
            rates.add(effectiveRate);
            _prepare(r, p);
          },
        ),
      ),
    );
    expect(rates.last, 2);
    clock.emit(_anchor(rate: .5, advancing: false));
    await tester.pump();
    expect(rates.last, .5);
    await _mount(tester, const SizedBox.shrink());
  });

  testWidgets(
    'frame time uses media anchor; pause freezes and invalidation clears',
    (tester) async {
      var now = 0;
      final clock = _Clock(_anchor());
      final renderer = _renderer();
      addTearDown(renderer.dispose);
      addTearDown(clock.events.close);
      final positions = <int>[];
      await _mount(
        tester,
        _host(
          DanmakuWindowScreen<void>(
            renderer: renderer,
            clock: clock,
            size: const Size(320, 120),
            monotonicUs: () => now,
            frameTimeUs: () => now,
            prepareFrame: (r, p, {required effectiveRate}) {
              positions.add(p);
              _prepare(r, p);
            },
          ),
        ),
      );
      now = 100000;
      await tester.pump(const Duration(milliseconds: 100));
      expect(positions.last, 100000);
      final stoppedAt = positions.last;
      clock.emit(_anchor(position: 200000, observed: now, advancing: false));
      // 暂停保持屏幕当前帧，原生校准差留到恢复后的连续帧处理。
      expect(positions.last, stoppedAt);
      final frames = positions.length;
      now = 900000;
      await tester.pump(const Duration(seconds: 1));
      expect(positions.last, stoppedAt);
      expect(positions.length, frames + 1);
      final previousHandle = renderer.interaction;
      final layouts = renderer.rasters.layouts;
      clock.emit(null);
      expect(previousHandle.isValid, isFalse);
      expect(renderer.activeCount, 0);
      clock.emit(
        _anchor(
          position: 500000,
          observed: now,
          continuity: 1,
          advancing: false,
        ),
      );
      expect(renderer.validFromUs, 0);
      expect(renderer.rasters.layouts, layouts);
      await tester.pump();
      expect(positions.last, 500000);
      await _mount(tester, const SizedBox.shrink());
      expect(clock.events.hasListener, isFalse);
    },
  );

  testWidgets(
    'expired extrapolation stops frames until a fresh anchor arrives',
    (tester) async {
      var now = 0;
      final clock = _Clock(_anchor(validFor: 100000));
      final renderer = _renderer();
      addTearDown(renderer.dispose);
      addTearDown(clock.events.close);
      final positions = <int>[];
      await _mount(
        tester,
        _host(
          DanmakuWindowScreen<void>(
            renderer: renderer,
            clock: clock,
            size: const Size(320, 120),
            monotonicUs: () => now,
            frameTimeUs: () => now,
            prepareFrame: (r, p, {required effectiveRate}) {
              positions.add(p);
              _prepare(r, p);
            },
          ),
        ),
      );
      now = 200000;
      await tester.pump(const Duration(milliseconds: 200));
      expect(positions.last, 100000);
      final frames = positions.length;
      now = 2000000;
      await tester.pump(const Duration(seconds: 1));
      expect(positions.length, frames);
      clock.emit(_anchor(position: 1000000, observed: now, validFor: 100000));
      now += 50000;
      await tester.pump(const Duration(milliseconds: 50));
      expect(positions.last, 1050000);
      await _mount(tester, const SizedBox.shrink());
    },
  );

  testWidgets(
    'paused input completion wakes one update and subscriptions detach on unmount',
    (tester) async {
      final clock = _Clock(_anchor(position: 500000, advancing: false));
      final updates = StreamController<Object?>.broadcast(sync: true);
      final renderer = _renderer();
      addTearDown(renderer.dispose);
      addTearDown(clock.events.close);
      addTearDown(updates.close);
      var ready = false;
      var frames = 0;
      await _mount(
        tester,
        _host(
          DanmakuWindowScreen<void>(
            renderer: renderer,
            clock: clock,
            inputChanges: updates.stream,
            size: const Size(320, 120),
            monotonicUs: () => 0,
            frameTimeUs: () => 0,
            prepareFrame: (r, p, {required effectiveRate}) {
              frames++;
              if (ready) _prepare(r, p);
            },
          ),
        ),
      );
      expect(renderer.activeCount, 0);
      final before = frames;
      ready = true;
      updates.add(null);
      await tester.pump();
      expect(renderer.activeCount, 1);
      expect(frames, before + 1);
      await tester.pump(const Duration(seconds: 1));
      expect(frames, before + 1);
      await _mount(tester, const SizedBox.shrink());
      expect(clock.events.hasListener, isFalse);
      expect(updates.hasListener, isFalse);
    },
  );

  testWidgets(
    'hiding stops work; showing evaluates absolute time; clock replacement detaches old events',
    (tester) async {
      var now = 0;
      final first = _Clock(_anchor());
      final second = _Clock(_anchor(position: 800000, advancing: false));
      final renderer = _renderer();
      addTearDown(renderer.dispose);
      addTearDown(first.events.close);
      addTearDown(second.events.close);
      final positions = <int>[];
      Widget screen(_Clock clock, double opacity, {bool enabled = true}) =>
          _host(
            TickerMode(
              enabled: enabled,
              child: DanmakuWindowScreen<void>(
                renderer: renderer,
                clock: clock,
                opacity: opacity,
                size: const Size(320, 120),
                monotonicUs: () => now,
                frameTimeUs: () => now,
                prepareFrame: (r, p, {required effectiveRate}) {
                  positions.add(p);
                  _prepare(r, p);
                },
              ),
            ),
          );
      await _mount(tester, screen(first, 1));
      await _mount(tester, screen(first, 0));
      final before = positions.length;
      now = 500000;
      await tester.pump(const Duration(milliseconds: 500));
      expect(positions.length, before);
      await _mount(tester, screen(first, 1));
      await tester.pump();
      expect(positions.last, 500000);
      await _mount(tester, screen(first, 1, enabled: false));
      final mutedFrames = positions.length;
      now = 1500000;
      await tester.pump(const Duration(seconds: 1));
      expect(positions.length, mutedFrames);
      await _mount(tester, screen(first, 1));
      expect(positions.last, 1500000);
      await _mount(tester, screen(second, 1));
      expect(first.events.hasListener, isFalse);
      expect(positions.last, 800000);
      first.emit(null);
      expect(renderer.activeCount, 1);
      await _mount(tester, const SizedBox.shrink());
      expect(second.events.hasListener, isFalse);
    },
  );
}
