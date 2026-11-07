import 'dart:math' as math;
import 'dart:ui';

import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/interaction.dart';

typedef DensityTag = ({int weight, int sourceMs});

Map<String, int> weightCounts(Iterable<DanmakuElem> elements) {
  final counts = <String, int>{};
  for (final e in elements) {
    counts.update('${e.weight}', (v) => v + 1, ifAbsent: () => 1);
  }
  return counts;
}

/// 只统计与视口相交的显示项；记录几何可见面积，不能等同于逐字可读性。
/// 拥挤统计在采集完成后计算，不把 O(n²) 比较放进实际播放帧。
class DanmakuDensityMetrics {
  DanmakuDensityMetrics({
    required Iterable<DanmakuElem> input,
    required this.size,
  }) {
    for (final e in input) {
      _input.update(e.weight, (v) => v + 1, ifAbsent: () => 1);
      (_inputBuckets[e.progress ~/ 100] ??= []).add(e.weight);
    }
  }

  final Size size;
  final _input = <int, int>{};
  final _inputBuckets = <int, List<int>>{};
  final _seen = <Object>{};
  final _halfSeen = <Object>{};
  final _shown = <int, int>{};
  final _halfShown = <int, int>{};
  final _shownBuckets = <int, List<int>>{};
  final _delays = <int, List<int>>{};
  final _itemSeconds = <int, double>{};
  final _areaSeconds = <int, double>{};
  Map<int, double> _previousCounts = {};
  Map<int, double> _previousFractions = {};
  final _crowdingFrames = <List<({int weight, Rect bounds})>>[];
  int? _previousUs;
  int? _lastCrowdingUs;
  int peakOnScreen = 0;

  void sample(List<DanmakuDisplaySnapshot<DensityTag>> snapshots, int mediaUs) {
    if (_previousUs != null && mediaUs < _previousUs!) {
      throw ArgumentError('测量时钟必须单调推进');
    }
    final viewport = Offset.zero & size;
    final counts = <int, double>{};
    final fractions = <int, double>{};
    final crowding = <({int weight, Rect bounds})>[];
    final captureCrowding =
        _lastCrowdingUs == null || mediaUs - _lastCrowdingUs! >= 200000;
    var onScreen = 0;
    for (final item in snapshots) {
      final tag = item.extra;
      if (tag == null || !item.bounds.overlaps(viewport)) continue;
      final clipped = item.bounds.intersect(viewport);
      final area = item.bounds.width * item.bounds.height;
      if (clipped.isEmpty || area <= 0) continue;
      onScreen++;
      final fraction = (clipped.width * clipped.height / area).clamp(0.0, 1.0);
      counts.update(tag.weight, (v) => v + 1, ifAbsent: () => 1);
      fractions.update(
        tag.weight,
        (v) => v + fraction,
        ifAbsent: () => fraction,
      );
      if (_seen.add(item.identity)) {
        _shown.update(tag.weight, (v) => v + 1, ifAbsent: () => 1);
        (_shownBuckets[tag.sourceMs ~/ 100] ??= []).add(tag.weight);
        (_delays[tag.weight] ??= []).add(
          math.max(0, mediaUs - tag.sourceMs * 1000),
        );
      }
      if (fraction >= .5 && _halfSeen.add(item.identity)) {
        _halfShown.update(tag.weight, (v) => v + 1, ifAbsent: () => 1);
      }
      if (captureCrowding) crowding.add((weight: tag.weight, bounds: clipped));
    }
    peakOnScreen = math.max(peakOnScreen, onScreen);
    final seconds = _previousUs == null
        ? 0.0
        : (mediaUs - _previousUs!) / 1000000;
    for (final weight in {..._previousCounts.keys, ...counts.keys}) {
      _itemSeconds.update(
        weight,
        (v) =>
            v +
            ((_previousCounts[weight] ?? 0) + (counts[weight] ?? 0)) *
                seconds /
                2,
        ifAbsent: () =>
            ((_previousCounts[weight] ?? 0) + (counts[weight] ?? 0)) *
            seconds /
            2,
      );
      _areaSeconds.update(
        weight,
        (v) =>
            v +
            ((_previousFractions[weight] ?? 0) + (fractions[weight] ?? 0)) *
                seconds /
                2,
        ifAbsent: () =>
            ((_previousFractions[weight] ?? 0) + (fractions[weight] ?? 0)) *
            seconds /
            2,
      );
    }
    _previousCounts = counts;
    _previousFractions = fractions;
    _previousUs = mediaUs;
    if (captureCrowding) {
      _crowdingFrames.add(crowding);
      _lastCrowdingUs = mediaUs;
    }
  }

  Map<String, Object?> summarize() {
    final overlapAreas = <int, double>{};
    final visibleAreas = <int, double>{};
    for (final frame in _crowdingFrames) {
      for (var i = 0; i < frame.length; i++) {
        final item = frame[i];
        final area = item.bounds.width * item.bounds.height;
        var overlap = 0.0;
        for (var j = 0; j < frame.length; j++) {
          if (i == j || !item.bounds.overlaps(frame[j].bounds)) continue;
          final rect = item.bounds.intersect(frame[j].bounds);
          overlap += rect.width * rect.height;
        }
        visibleAreas.update(item.weight, (v) => v + area, ifAbsent: () => area);
        final crowded = math.min(area, overlap);
        overlapAreas.update(
          item.weight,
          (v) => v + crowded,
          ifAbsent: () => crowded,
        );
      }
    }
    var rankLoss = 0;
    var bucketShown = 0;
    for (final entry in _shownBuckets.entries) {
      final sorted = _inputBuckets[entry.key]!.toList()
        ..sort((a, b) => b.compareTo(a));
      final available = <int, int>{};
      for (final weight in sorted.take(entry.value.length)) {
        available.update(weight, (v) => v + 1, ifAbsent: () => 1);
      }
      for (final weight in entry.value) {
        if ((available[weight] ?? 0) == 0) {
          rankLoss++;
        } else {
          available[weight] = available[weight]! - 1;
        }
      }
      bucketShown += entry.value.length;
    }
    final weights = _input.keys.toList()..sort((a, b) => b.compareTo(a));
    return {
      'displayed': _seen.length,
      'halfVisible': _halfSeen.length,
      'peakOnScreen': peakOnScreen,
      'displayedByWeight': {
        for (final weight in weights) '$weight': _shown[weight] ?? 0,
      },
      'weightProfile': {
        for (final weight in weights)
          '$weight': {
            'input': _input[weight],
            'visible': _shown[weight] ?? 0,
            'visibleRate': (_shown[weight] ?? 0) / _input[weight]!,
            'halfVisible': _halfShown[weight] ?? 0,
            'onScreenItemSeconds': _itemSeconds[weight] ?? 0,
            'visibleAreaItemSeconds': _areaSeconds[weight] ?? 0,
            // 包围盒相交率是拥挤的近似量，不能推断实际文字像素被遮挡的比例。
            'boundsCrowdingRate': (visibleAreas[weight] ?? 0) == 0
                ? 0
                : (overlapAreas[weight] ?? 0) / visibleAreas[weight]!,
            'entryDelayP95Ms': _delays[weight] == null
                ? null
                : _percentile(_delays[weight]!) / 1000,
          },
      },
      // 假定同桶各项可互换时的理想top-N；跨模式/不同字宽会使该上界无法达到。
      'bucketTopNMissingSlots': rankLoss,
      'bucketTopNComparedSlots': bucketShown,
      'bucketTopNMissingRate': bucketShown == 0 ? 0 : rankLoss / bucketShown,
      'crowdingSamples': _crowdingFrames.length,
    };
  }

  static int _percentile(List<int> input) {
    final values = input.toList()..sort();
    return values[(values.length * .95).floor()];
  }
}
