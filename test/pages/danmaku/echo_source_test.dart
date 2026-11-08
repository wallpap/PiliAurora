import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/painting.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/pages/danmaku/window_coordinator.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/danmaku/echo_source.dart';
import 'package:pili_aurora/pages/danmaku/timeline_range.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('rule invalidation allows current echo and local removal preserves other entries', () {
    final origin = _Source();
    final source = DanmakuEchoSource(origin);
    final renderer = DanmakuWindowRenderer<DanmakuExtra>(
      option: const DanmakuOption(massiveMode: true),
      size: const Size(640, 360),
    );
    final coordinator = DanmakuWindowCoordinator<DanmakuExtra>(
      source: source,
      renderer: renderer,
      contentOf: source.contentFor,
    );
    addTearDown(() {
      coordinator.dispose();
      renderer.dispose();
      source.dispose();
    });
    addTearDown(origin.events.close);
    origin.state = DanmakuCoverageState.invalidated;
    origin.events.add(
      const DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.invalidated,
        ruleRevision: 12,
      ),
    );
    source
      ..add(
        DanmakuContentItem(
          'first',
          selfSend: true,
          extra: VideoDanmaku(id: 7, mid: 'self'),
        ),
        0,
      )
      ..add(
        DanmakuContentItem(
          'second',
          selfSend: true,
          extra: VideoDanmaku(id: 8, mid: 'self'),
        ),
        0,
      );
    coordinator.prepareFrame(renderer, 0);
    renderer.present(0, allowUnprepared: true);
    expect(renderer.interaction.snapshot.map((item) => item.text), [
      'first',
      'second',
    ]);
    source.remove(7);
    coordinator.prepareFrame(renderer, 0);
    renderer.present(0, allowUnprepared: true);
    expect(renderer.interaction.snapshot.single.text, 'second');
    origin.state = DanmakuCoverageState.loaded;
    origin.events.add(
      const DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.ready,
        ruleRevision: 11,
      ),
    );
    expect(source.readRange(0, 1000).ruleRevision, 2);
    origin.events.add(
      const DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.ready,
        ruleRevision: 12,
      ),
    );
    coordinator.prepareFrame(renderer, 0);
    renderer.present(0, allowUnprepared: true);
    expect(renderer.interaction.snapshot.single.text, 'second');
  });

  test('echo without server id enters while remote coverage is missing', () {
    final origin = _Source()..state = DanmakuCoverageState.missing;
    addTearDown(origin.events.close);
    final source = DanmakuEchoSource(origin);
    final renderer = DanmakuWindowRenderer<DanmakuExtra>(
      option: const DanmakuOption(),
      size: const Size(640, 360),
    );
    final coordinator = DanmakuWindowCoordinator<DanmakuExtra>(
      source: source,
      renderer: renderer,
      contentOf: source.contentFor,
    );
    addTearDown(() {
      coordinator.dispose();
      renderer.dispose();
      source.dispose();
    });
    source.add(DanmakuContentItem('local', selfSend: true), 0);
    coordinator.prepareFrame(renderer, 0);
    renderer.present(0, allowUnprepared: true);
    expect(renderer.interaction.snapshot.single.text, 'local');
    expect(renderer.interaction.snapshot.single.selfSend, isTrue);
  });

  test(
    'send echo stays stable after server arrival and removal invalidates',
    () {
      final origin = _Source();
      final source = DanmakuEchoSource(origin);
      addTearDown(origin.events.close);
      addTearDown(source.dispose);
      final changes = <DanmakuSourceChange>[];
      final subscription = source.changes.listen(changes.add);
      addTearDown(subscription.cancel);
      final content = DanmakuContentItem<DanmakuExtra>(
        'sent',
        selfSend: true,
        extra: VideoDanmaku(id: 7, mid: 'self'),
      );
      source
        ..add(content, 1000000)
        ..add(content, 1000000);
      final before = source.readRange(0, 2000000).entries.single.element;
      origin.elements.add(
        DanmakuElem(id: Int64(7), idStr: '7', progress: 1100, content: 'sent'),
      );
      final after = source.readRange(0, 2000000).entries.single.element;
      expect(identical(before, after), isTrue);
      expect(source.contentFor(after), same(content));
      source.remove(7);
      expect(source.readRange(0, 2000000).entries, isEmpty);
      expect(changes.map((e) => e.kind), [
        DanmakuSourceChangeKind.ready,
        DanmakuSourceChangeKind.invalidated,
        DanmakuSourceChangeKind.ready,
      ]);
    },
  );
}

class _Source implements DanmakuTimelineSource {
  final elements = <DanmakuElem>[];
  final events = StreamController<DanmakuSourceChange>.broadcast(sync: true);
  DanmakuCoverageState state = DanmakuCoverageState.loaded;
  @override
  Stream<DanmakuSourceChange> get changes => events.stream;
  @override
  Future<void> ensureRange(int startUs, int endUs) async {}
  @override
  DanmakuTimelineRange readRange(
    int startUs,
    int endUs, {
    int? maxEntriesPerBucket,
  }) => DanmakuTimelineRange(
    startUs: startUs,
    endUs: endUs,
    revision: 0,
    entries: elements
        .where(
          (element) =>
              element.progress * 1000 >= startUs &&
              element.progress * 1000 < endUs,
        )
        .map(DanmakuTimelineEntry.new),
    coverage: [
      DanmakuRangeCoverage(startUs, endUs, state),
    ],
  );
}
