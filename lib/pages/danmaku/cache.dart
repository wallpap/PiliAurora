import 'dart:collection';

import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:PiliPlus/utils/danmaku_utils.dart';

/// 按 100 毫秒分桶保存弹幕，按分段淘汰以避免只留下不完整分段。
class DanmakuCache {
  DanmakuCache({
    this.maxBuckets = 6000,
    this.maxElements = 30000,
    this.maxElementsPerBucket = 8,
    this.maxSegments = 4,
  });

  final int maxBuckets;
  final int maxElements;
  final int maxElementsPerBucket;
  final int maxSegments;

  final _buckets = <int, List<DanmakuElem>>{};
  final _segmentBuckets = <int, Set<int>>{};
  final _segmentOrder = Queue<int>();
  final _loadedSegments = <int>{};
  int _elementCount = 0;

  int get bucketCount => _buckets.length;
  int get elementCount => _elementCount;
  bool containsSegment(int segment) => _loadedSegments.contains(segment);

  void clear() {
    _buckets.clear();
    _segmentBuckets.clear();
    _segmentOrder.clear();
    _loadedSegments.clear();
    _elementCount = 0;
  }

  List<DanmakuElem>? getAt(int progress) {
    final segment = DmUtils.calcSegment(progress);
    if (_loadedSegments.contains(segment) && _segmentOrder.last != segment) {
      // 实际播放中的分段优先保留，旧分段先淘汰。
      _segmentOrder
        ..remove(segment)
        ..addLast(segment);
    }
    return _buckets[progress ~/ 100];
  }

  void addSegmentBuckets(int segment, Map<int, List<DanmakuElem>> buckets) {
    if (_loadedSegments.contains(segment)) return;
    _loadedSegments.add(segment);
    _segmentOrder.addLast(segment);
    final segmentBuckets = _segmentBuckets[segment] = <int>{};

    for (final entry in buckets.entries) {
      final bucket = entry.key;
      final items = entry.value;
      if (DmUtils.calcSegment(bucket * 100) != segment) continue;
      // 6 分钟最多有 3600 个分桶，每桶 8 条可将单段限制在约 2.9 万条。
      if (items.length > maxElementsPerBucket) {
        items.removeRange(maxElementsPerBucket, items.length);
      }
      _buckets[bucket] = items;
      segmentBuckets.add(bucket);
      _elementCount += items.length;
    }

    _trim(protectedSegment: segment);
  }

  void addFileElements(Iterable<DanmakuElem> elements) {
    for (final element in elements) {
      final segment = DmUtils.calcSegment(element.progress);
      if (_loadedSegments.add(segment)) {
        _segmentOrder.addLast(segment);
      }
      final bucket = element.progress ~/ 100;
      (_buckets[bucket] ??= <DanmakuElem>[]).add(element);
      (_segmentBuckets[segment] ??= <int>{}).add(bucket);
      _elementCount++;
    }
  }

  void _trim({required int protectedSegment}) {
    while (_segmentOrder.length > 1 &&
        (_segmentOrder.length > maxSegments ||
            _buckets.length > maxBuckets ||
            _elementCount > maxElements)) {
      final oldest = _segmentOrder.first;
      if (oldest == protectedSegment) {
        _segmentOrder
          ..removeFirst()
          ..addLast(oldest);
        continue;
      }
      _segmentOrder.removeFirst();
      _loadedSegments.remove(oldest);
      final buckets = _segmentBuckets.remove(oldest);
      if (buckets == null) continue;
      for (final bucket in buckets) {
        _elementCount -= _buckets.remove(bucket)?.length ?? 0;
      }
    }
  }
}
