import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/cache.dart';
import 'package:pili_aurora/pages/danmaku/timeline_range.dart';
import 'package:pili_aurora/pages/danmaku/window_coordinator.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/pages/danmaku/window_screen.dart';
import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';

class _Source implements DanmakuTimelineSource {
  final cache = DanmakuCache();
  final events = StreamController<DanmakuSourceChange>.broadcast(sync: true);
  final requests = <(int, int)>[];
  int revision = 0;
  @override
  Stream<DanmakuSourceChange> get changes => events.stream;
  @override
  DanmakuTimelineRange readRange(
    int startUs,
    int endUs, {
    int? maxEntriesPerBucket,
  }) => cache.readRange(
    startUs,
    endUs,
    ruleRevision: revision,
    maxEntriesPerBucket: maxEntriesPerBucket,
  );
  @override
  Future<void> ensureRange(int startUs, int endUs) async {
    requests.add((startUs, endUs));
  }

  void load(List<DanmakuElem> elements) {
    cache.addFileElements(elements);
    events.add(
      DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.ready,
        ruleRevision: revision,
      ),
    );
  }

  void invalidate() {
    revision++;
    cache.clear();
    events.add(
      DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.invalidated,
        ruleRevision: revision,
      ),
    );
  }
}

class _Clock implements PlaybackMediaClock {
  _Clock({this.advancing = true});
  final bool advancing;
  @override
  PlaybackMediaAnchor get currentMediaAnchor => PlaybackMediaAnchor(
    positionUs: 0,
    observedAtUs: 0,
    effectiveRate: 1,
    advancing: advancing,
    ready: true,
    continuity: 0,
    validForUs: 10000000,
  );
  final events = StreamController<PlaybackMediaAnchor?>.broadcast();
  @override
  Stream<PlaybackMediaAnchor?> get mediaAnchors => events.stream;
}

DanmakuElem _dm(String text, int milliseconds) =>
    DanmakuElem(content: text, progress: milliseconds);
DanmakuWindowRenderer<void> _renderer() => DanmakuWindowRenderer(
  option: const DanmakuOption(
    duration: 8,
    fontSize: 16,
    safeArea: false,
    massiveMode: true,
  ),
  size: const Size(500, 200),
);
DanmakuContentItem<void> _content(DanmakuElem element) => DanmakuContentItem(
  element.content,
  color: const Color(0xffffffff),
  selfSend: true,
);

void main() {
  test('source selection and per-frame preparation fill twelve slots by relative weight', () {
    final source = _Source()
      ..load([
        for (final group in [(0, 10), (3, 12), (5, 7), (7, 2), (10, 2)])
          for (var i = 0; i < group.$2; i++)
            _dm('${group.$1}-$i', 0)..weight = group.$1,
      ]);
    const option = DanmakuOption(fontSize: 16, safeArea: false, duration: 8);
    final measure = DanmakuWindowRenderer<int>(
      option: option,
      size: const Size(500, 500),
    );
    final trackHeight = measure.rasters.measureTrackHeight();
    measure.dispose();
    final renderer = DanmakuWindowRenderer<int>(
      option: option,
      size: Size(500, trackHeight * 12 + .01),
    );
    final coordinator = DanmakuWindowCoordinator<int>(
      source: source,
      renderer: renderer,
      contentOf: (element) => DanmakuContentItem<int>(
        element.content,
        color: const Color(0xffffffff),
        extra: element.weight,
      ),
    );
    addTearDown(renderer.dispose);
    addTearDown(coordinator.dispose);
    addTearDown(source.events.close);
    coordinator.prepareFrame(renderer, 0);
    renderer.present(0, allowUnprepared: true);
    expect(renderer.activeCount, 8);
    coordinator.prepareFrame(renderer, 0);
    renderer.present(0, allowUnprepared: true);
    final distribution = <int, int>{};
    for (final item in renderer.interaction.snapshot) {
      distribution.update(item.extra!, (count) => count + 1, ifAbsent: () => 1);
    }
    expect(distribution, {10: 2, 7: 2, 5: 7, 3: 1});
    expect(renderer.activeCount, 12);
    expect(
      renderer.interaction.snapshot.singleWhere((item) => item.extra == 3).text,
      '3-0',
    );
  });

  test(
    'priority preparation preserves original times and incomplete frontier',
    () {
      final source = _Source()
        ..load([
          _dm('low', 0)..weight = 1,
          _dm('middle', 50)..weight = 3,
          _dm('high', 90)..weight = 10,
        ]);
      final renderer = _renderer();
      final converted = <String>[];
      final coordinator = DanmakuWindowCoordinator<void>(
        source: source,
        renderer: renderer,
        preparePerFrame: 1,
        contentOf: (e) {
          converted.add(e.content);
          return _content(e);
        },
      );
      addTearDown(renderer.dispose);
      addTearDown(coordinator.dispose);
      addTearDown(source.events.close);
      coordinator.prepareFrame(renderer, 0);
      expect(converted, ['high', 'middle', 'low']);
      expect(renderer.validUntilUs, 0);
      renderer.present(0, allowUnprepared: true);
      expect(renderer.activeCount, 0);
      renderer.present(90000, allowUnprepared: true);
      expect(renderer.interaction.snapshot.single.text, 'high');
      coordinator.prepareFrame(renderer, 0);
      expect(renderer.validUntilUs, 0);
      coordinator.prepareFrame(renderer, 0);
      expect(renderer.validUntilUs, greaterThanOrEqualTo(100000));
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();

  test('local invalidation preserves unrelated active items and ignores stale ready', () {
    final source = _Source()..load([_dm('keep', 0), _dm('remove', 100)]);
    final renderer = _renderer();
    final coordinator = DanmakuWindowCoordinator(
      source: source,
      renderer: renderer,
      contentOf: _content,
    );
    addTearDown(renderer.dispose);
    addTearDown(coordinator.dispose);
    addTearDown(source.events.close);
    coordinator.prepareFrame(renderer, 0);
    renderer.present(150000, allowUnprepared: true);
    expect(renderer.activeCount, 2);
    source.events.add(
      const DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.invalidated,
        ruleRevision: 2,
        startUs: 100000,
        endUs: 200000,
      ),
    );
    expect(renderer.activeCount, 1);
    coordinator.prepareFrame(renderer, 150000);
    renderer.present(150000, allowUnprepared: true);
    expect(renderer.activeCount, 1);
    source.events.add(
      const DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.ready,
        ruleRevision: 1,
        startUs: 100000,
        endUs: 200000,
      ),
    );
    coordinator.prepareFrame(renderer, 150000);
    renderer.present(150000, allowUnprepared: true);
    expect(renderer.activeCount, 1);
    source.events.add(
      const DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.ready,
        ruleRevision: 2,
        startUs: 100000,
        endUs: 200000,
      ),
    );
    coordinator.prepareFrame(renderer, 150000);
    renderer.present(150000, allowUnprepared: true);
    // 已经越过当前生效下界的旧条目不会重新投放。
    expect(renderer.activeCount, 1);
  });

  test('equal timestamps prepare incrementally without claiming a complete frontier', () {
    final source = _Source()
      ..load([for (var i = 0; i < 6; i++) _dm('item$i', 0)]);
    final renderer = _renderer();
    final coordinator = DanmakuWindowCoordinator(
      source: source,
      renderer: renderer,
      contentOf: _content,
      preparePerFrame: 2,
    );
    addTearDown(renderer.dispose);
    addTearDown(coordinator.dispose);
    addTearDown(source.events.close);
    coordinator.prepareFrame(renderer, 0);
    expect(renderer.validUntilUs, 0);
    expect(renderer.present(0), isFalse);
    expect(renderer.present(0, allowUnprepared: true), isTrue);
    expect(renderer.activeCount, 2);
    coordinator.prepareFrame(renderer, 16000);
    renderer.present(16000, allowUnprepared: true);
    expect(renderer.activeCount, 4);
    coordinator.prepareFrame(renderer, 32000);
    renderer.present(32000, allowUnprepared: true);
    expect(renderer.activeCount, 6);
    expect(renderer.validUntilUs, greaterThan(0));
  });

  test('missing coverage waits, ready input fills it and invalidation clears immediately', () async {
    final source = _Source();
    final renderer = _renderer();
    final coordinator = DanmakuWindowCoordinator(
      source: source,
      renderer: renderer,
      contentOf: _content,
    );
    addTearDown(renderer.dispose);
    addTearDown(coordinator.dispose);
    addTearDown(source.events.close);
    coordinator.prepareFrame(renderer, 0);
    await Future<void>.delayed(Duration.zero);
    expect(source.requests, [(0, 2000000)]);
    expect(renderer.validUntilUs, 0);
    source.load([_dm('loaded', 0)]);
    coordinator.prepareFrame(renderer, 100000);
    renderer.present(100000, allowUnprepared: true);
    expect(renderer.activeCount, 1);
    source.invalidate();
    expect(renderer.activeCount, 0);
    expect(renderer.validFromUs, 100000);
    source.load([_dm('new rules', 100)]);
    coordinator.prepareFrame(renderer, 100000);
    renderer.present(100000, allowUnprepared: true);
    expect(renderer.activeCount, 1);
  });

  test(
    'refill reaches its target then stops reads until inner threshold',
    () {
      final source = _Source()..load([]);
      final renderer = _renderer();
      final coordinator = DanmakuWindowCoordinator(
        source: source,
        renderer: renderer,
        contentOf: _content,
      );
      addTearDown(renderer.dispose);
      addTearDown(coordinator.dispose);
      addTearDown(source.events.close);
      for (var i = 0; i < 6; i++) {
        coordinator.prepareFrame(renderer, 0);
      }
      expect(renderer.validUntilUs, 2000000);
      final requests = source.requests.length;
      coordinator.prepareFrame(renderer, 1000000);
      expect(source.requests.length, requests);
      expect(renderer.validUntilUs, 2000000);
      coordinator.prepareFrame(renderer, 1600000);
      expect(renderer.validUntilUs, greaterThan(2000000));
    },
  );

  test(
    'observed rate scales real-time lookahead without resetting trajectories',
    () {
      final source = _Source()..load([]);
      final renderer = _renderer();
      final coordinator = DanmakuWindowCoordinator(
        source: source,
        renderer: renderer,
        contentOf: _content,
      );
      addTearDown(renderer.dispose);
      addTearDown(coordinator.dispose);
      addTearDown(source.events.close);
      final generation = renderer.generation;
      for (var i = 0; i < 12; i++) {
        coordinator.prepareFrame(renderer, 0, effectiveRate: 2);
      }
      expect(renderer.validUntilUs, 4000000);
      expect(coordinator.needsPreparation, isFalse);
      coordinator.prepareFrame(renderer, 3000000, effectiveRate: 2);
      expect(coordinator.needsPreparation, isFalse);
      coordinator.prepareFrame(renderer, 3100000, effectiveRate: 2);
      expect(coordinator.needsPreparation, isTrue);
      for (var i = 0; i < 12; i++) {
        coordinator.prepareFrame(renderer, 3100000, effectiveRate: 2);
      }
      expect(renderer.validUntilUs, 7100000);
      coordinator.prepareFrame(renderer, 3100000, effectiveRate: .5);
      expect(coordinator.needsPreparation, isFalse);
      expect(renderer.validUntilUs, 7100000);
      expect(renderer.generation, generation);
    },
  );

  test('repeated ready signals preserve fixed bucket sampling', () {
    final source = _Source()
      ..load([for (var i = 0; i < 200; i++) _dm('sample$i', 0)]);
    final renderer = _renderer();
    var converted = 0;
    final coordinator = DanmakuWindowCoordinator(
      source: source,
      renderer: renderer,
      preparePerFrame: 120,
      maxCandidatesPerBucket: 120,
      contentOf: (element) {
        converted++;
        return _content(element);
      },
    );
    addTearDown(renderer.dispose);
    addTearDown(coordinator.dispose);
    addTearDown(source.events.close);
    coordinator.prepareFrame(renderer, 0);
    expect(converted, 120);
    source.events.add(
      const DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.ready,
        ruleRevision: 0,
      ),
    );
    coordinator.prepareFrame(renderer, 16000);
    expect(converted, 120);
  });

  test('special candidates keep the per-bucket cap across ready replays', () {
    final source = _Source()
      ..load([for (var i = 0; i < 6; i++) _dm('script$i', 0)..mode = 7]);
    final renderer = _renderer();
    var converted = 0;
    final coordinator = DanmakuWindowCoordinator(
      source: source,
      renderer: renderer,
      preparePerFrame: 120,
      contentOf: (element) {
        converted++;
        return SpecialDanmakuContentItem<void>(
          element.content,
          duration: 1000,
          color: const Color(0xffffffff),
          fontSize: 16,
          translateXTween: ConstantTween<double>(.25),
          translateYTween: ConstantTween<double>(.25),
        );
      },
    );
    addTearDown(renderer.dispose);
    addTearDown(coordinator.dispose);
    addTearDown(source.events.close);
    coordinator.prepareFrame(renderer, 0);
    renderer.present(0, allowUnprepared: true);
    expect(converted, 4);
    expect(renderer.activeSpecialCount, 4);
    source.events.add(
      const DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.ready,
        ruleRevision: 0,
      ),
    );
    coordinator.prepareFrame(renderer, 16000);
    expect(converted, 4);
  });

  testWidgets(
    'paused source ready completes bounded preparation and stops scheduling',
    (tester) async {
      final source = _Source();
      final renderer = _renderer();
      final coordinator = DanmakuWindowCoordinator(
        source: source,
        renderer: renderer,
        contentOf: _content,
        preparePerFrame: 4,
      );
      addTearDown(renderer.dispose);
      addTearDown(coordinator.dispose);
      addTearDown(source.events.close);
      final clock = _Clock(advancing: false);
      addTearDown(clock.events.close);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(500, 200)),
            child: Center(
              child: SizedBox(
                width: 500,
                height: 200,
                child: DanmakuWindowScreen<void>(
                  renderer: renderer,
                  clock: clock,
                  size: const Size(500, 200),
                  inputChanges: coordinator.updates,
                  monotonicUs: () => 0,
                  frameTimeUs: () => 0,
                  prepareFrame: coordinator.prepareFrame,
                  needsPreparation: () => coordinator.needsPreparation,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(renderer.activeCount, 0);
      expect(coordinator.needsPreparation, isFalse);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.hasRunningAnimations, isFalse);
      source.load([for (var i = 0; i < 6; i++) _dm('arrived$i', 0)]);
      await tester.pump();
      expect(renderer.activeCount, 4);
      expect(coordinator.needsPreparation, isTrue);
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      expect(renderer.activeCount, 6);
      expect(coordinator.needsPreparation, isFalse);
      expect(tester.hasRunningAnimations, isFalse);
      source.invalidate();
      expect(renderer.activeCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
