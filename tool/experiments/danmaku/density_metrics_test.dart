import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/interaction.dart';

import 'density_metrics.dart';

DanmakuDisplaySnapshot<DensityTag> _item(int id, int weight, Rect bounds) =>
    DanmakuDisplaySnapshot(
      identity: id,
      text: '',
      extra: (weight: weight, sourceMs: 0),
      bounds: bounds,
      selectable: true,
      selected: false,
    );

void main() {
  test(
    'clips offscreen items, integrates visible area and counts unique exposure',
    () {
      final metrics = DanmakuDensityMetrics(
        input: [DanmakuElem(weight: 3)],
        size: const Size(100, 100),
      )..sample([_item(0, 3, const Rect.fromLTWH(100, 0, 100, 20))], 0);
      expect(metrics.summarize()['displayed'], 0);
      metrics
        ..sample([_item(0, 3, const Rect.fromLTWH(50, 0, 100, 20))], 500000)
        ..sample([_item(0, 3, const Rect.fromLTWH(50, 0, 100, 20))], 1000000);
      final result = metrics.summarize();
      expect(result['displayed'], 1);
      expect(result['halfVisible'], 1);
      final profile = (result['weightProfile']! as Map)['3'] as Map;
      expect(profile['visibleAreaItemSeconds'], closeTo(.375, 1e-9));
      expect(profile['boundsCrowdingRate'], 0);
    },
  );

  test('relative top N loss uses all weights and keeps equal weight ties equivalent', () {
    final input = [
      for (final group in [(0, 10), (3, 12), (5, 7), (7, 2), (10, 2)])
        for (var i = 0; i < group.$2; i++) DanmakuElem(weight: group.$1),
    ];
    final chosen = [10, 10, 7, 7, for (var i = 0; i < 7; i++) 5, 3];
    final good =
        DanmakuDensityMetrics(
          input: input,
          size: const Size(100, 100),
        )..sample([
          for (var i = 0; i < chosen.length; i++)
            _item(i, chosen[i], const Rect.fromLTWH(0, 0, 50, 20)),
        ], 0);
    expect(good.summarize()['bucketTopNMissingSlots'], 0);
    final bad = DanmakuDensityMetrics(input: input, size: const Size(100, 100))
      ..sample([
        for (var i = 0; i < 12; i++)
          _item(i, i < 10 ? 0 : 3, const Rect.fromLTWH(0, 0, 50, 20)),
      ], 0);
    expect(bad.summarize()['bucketTopNMissingSlots'], 11);
    expect(
      ((bad.summarize()['weightProfile']! as Map)['0']
          as Map)['boundsCrowdingRate'],
      1,
    );
  });
}
