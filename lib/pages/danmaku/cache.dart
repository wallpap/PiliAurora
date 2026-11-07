import 'dart:collection';
import 'dart:math' as math;

import 'package:pili_aurora/pages/danmaku/priority.dart';

import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/utils/danmaku_utils.dart';
import 'package:pili_aurora/utils/extension/iterable_ext.dart';
import 'package:pili_aurora/pages/danmaku/timeline_range.dart';
import 'package:pili_aurora/pages/danmaku/element_size.dart';

/// 按 100 毫秒分桶保存弹幕，按分段淘汰以避免只留下不完整分段。
class DanmakuCache {
  DanmakuCache({
    this.maxBuckets = 6000,
    this.maxElements = 36000,
    this.maxElementsPerBucket = danmakuCandidatesPerBucket,
    this.maxSegments = 4,
    this.maxBytes = defaultMaxBytes,
  });

  static const defaultMaxBytes = 20 * 1024 * 1024;
  static const elementSlotBytes = 64;
  static const bucketIndexBytes = 128;
  static const segmentIndexBytes = 128;

  final int maxBytes;
  final int maxBuckets;
  final int maxElements;
  final int maxElementsPerBucket;
  final int maxSegments;

  final _buckets = SplayTreeMap<int, List<DanmakuElem>>();
  final _segmentBuckets = <int, Set<int>>{};
  final _segmentOrder = Queue<int>();
  final _loadedSegments = <int>{};
  int _elementCount = 0;
  int _estimatedBytes = 0;
  final _segmentBytes = <int, int>{};
  int get estimatedBytes => _estimatedBytes;

  int _revision = 0;
  bool _fileComplete = false;

  DanmakuTimelineRange readRange(
    int startUs,
    int endUs, {
    int ruleRevision = 0,
    int? maxEntriesPerBucket,
    DanmakuCoverageState Function(int segment)? missingState,
  }) {
    if (startUs < 0 || endUs < startUs) {
      throw ArgumentError('弹幕范围需满足 0 <= startUs <= endUs');
    }
    if (maxEntriesPerBucket != null && maxEntriesPerBucket <= 0) {
      throw ArgumentError.value(maxEntriesPerBucket, 'maxEntriesPerBucket');
    }
    final coverage = <DanmakuRangeCoverage>[];
    const segmentUs = 360 * Duration.microsecondsPerSecond;
    var cursor = startUs;
    while (cursor < endUs) {
      final segment = cursor ~/ segmentUs;
      final end = math.min(endUs, (segment + 1) * segmentUs);
      final state = _fileComplete || _loadedSegments.contains(segment)
          ? DanmakuCoverageState.loaded
          : missingState?.call(segment) ?? DanmakuCoverageState.missing;
      if (coverage.isNotEmpty && coverage.last.state == state) {
        final previous = coverage.removeLast();
        coverage.add(DanmakuRangeCoverage(previous.startUs, end, state));
      } else {
        coverage.add(DanmakuRangeCoverage(cursor, end, state));
      }
      cursor = end;
    }
    final entries = <DanmakuTimelineEntry>[];
    var bucket = _buckets.firstKeyAfter(startUs ~/ 100000 - 1);
    while (bucket != null && bucket * 100000 < endUs) {
      final items = _buckets[bucket]!;
      final lower = items.lowerBoundByKey(
        (item) => item.progress * 1000,
        startUs,
      );
      final upper = items.lowerBoundByKey(
        (item) => item.progress * 1000,
        endUs,
      );
      final selected = selectDanmakuPriority(
        items.sublist(lower, upper),
        maxEntriesPerBucket ?? upper - lower,
        compareDanmakuPriority,
      );
      entries.addAll(selected.map(DanmakuTimelineEntry.new));
      bucket = _buckets.firstKeyAfter(bucket);
    }
    return DanmakuTimelineRange(
      startUs: startUs,
      endUs: endUs,
      revision: _revision,
      ruleRevision: ruleRevision,
      entries: entries,
      coverage: coverage,
    );
  }

  static List<DanmakuElem> _ordered(List<DanmakuElem> items) {
    // 在写入边界固定同时间戳来源次序，热帧读取不再复制并排序整个桶。
    final indexed = items.indexed.toList()
      ..sort((a, b) {
        final time = a.$2.progress.compareTo(b.$2.progress);
        return time == 0 ? a.$1.compareTo(b.$1) : time;
      });
    return [for (final (_, item) in indexed) item];
  }

  int get bucketCount => _buckets.length;
  int get elementCount => _elementCount;
  bool containsSegment(int segment) => _loadedSegments.contains(segment);

  Iterable<DanmakuElem> peekRange(int start, int end, {int limit = 64}) sync* {
    var remaining = limit;
    for (var bucket = start ~/ 100; bucket * 100 < end; bucket++) {
      final elements = _buckets[bucket];
      if (elements == null) continue;
      for (final element in elements) {
        if (remaining <= 0) return;
        if (element.progress < start || element.progress >= end) continue;
        yield element;
        remaining--;
      }
    }
  }

  void clear() {
    _revision++;
    _fileComplete = false;
    _buckets.clear();
    _segmentBuckets.clear();
    _segmentOrder.clear();
    _loadedSegments.clear();
    _elementCount = 0;
    _estimatedBytes = 0;
    _segmentBytes.clear();
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
    final retained = DanmakuPriorityRetention(
      maxElements: maxElements,
      maxPerBucket: maxElementsPerBucket,
      maxBytes: maxBytes,
      baseBytes: segmentIndexBytes,
    );
    var index = 0;
    for (final entry in buckets.entries) {
      if (DmUtils.calcSegment(entry.key * 100) != segment) continue;
      for (final item in entry.value) {
        retained.add(index++, item);
      }
    }
    // 单条超限时保持缺失状态，避免把未缓存的数据标为完整。
    if (buckets.values.any((items) => items.isNotEmpty) && retained.isEmpty) {
      return;
    }
    final selected = retained.buckets;
    final segmentBytes = retained.estimatedBytes;
    if (segmentBytes > maxBytes) return;
    _segmentBytes[segment] = segmentBytes;
    _estimatedBytes += segmentBytes;
    _revision++;
    _loadedSegments.add(segment);
    _segmentOrder.addLast(segment);
    final segmentBuckets = _segmentBuckets[segment] = <int>{};

    for (final entry in selected.entries) {
      _buckets[entry.key] = _ordered(entry.value);
      segmentBuckets.add(entry.key);
      _elementCount += entry.value.length;
    }

    _trim(protectedSegment: segment);
  }

  void addFileElements(Iterable<DanmakuElem> elements) {
    _revision++;
    _fileComplete = true;
    final changed = <int>{};
    for (final element in elements) {
      final segment = DmUtils.calcSegment(element.progress);
      if (_loadedSegments.add(segment)) {
        _segmentOrder.addLast(segment);
        _segmentBytes[segment] = segmentIndexBytes;
        _estimatedBytes += segmentIndexBytes;
      }
      final bucket = element.progress ~/ 100;
      final bytes =
          estimateDanmakuElementBytes(element) +
          elementSlotBytes +
          (_buckets.containsKey(bucket) ? 0 : bucketIndexBytes);
      if (_estimatedBytes + bytes > maxBytes) {
        clear();
        return;
      }
      _estimatedBytes += bytes;
      _segmentBytes[segment] = _segmentBytes[segment]! + bytes;
      changed.add(bucket);
      (_buckets[bucket] ??= <DanmakuElem>[]).add(element);
      (_segmentBuckets[segment] ??= <int>{}).add(bucket);
      _elementCount++;
    }
    for (final bucket in changed) {
      _buckets[bucket] = _ordered(_buckets[bucket]!);
    }
  }

  /// 文件保留可重新读取的来源，内存仅持有最新请求段的处理结果。
  void replaceFileRange(
    int first,
    int last,
    Map<int, List<DanmakuElem>> buckets,
  ) {
    clear();
    final segmentBytes = <int, int>{
      for (var segment = first; segment <= last; segment++)
        segment: segmentIndexBytes,
    };
    for (final entry in buckets.entries) {
      final segment = DmUtils.calcSegment(entry.key * 100);
      if (segment < first || segment > last) continue;
      segmentBytes[segment] =
          segmentBytes[segment]! +
          bucketIndexBytes +
          entry.value.fold<int>(
            0,
            (sum, item) =>
                sum + estimateDanmakuElementBytes(item) + elementSlotBytes,
          );
    }
    final bytes = segmentBytes.values.fold<int>(0, (a, b) => a + b);
    if (bytes > maxBytes) return;
    _estimatedBytes = bytes;
    _segmentBytes.addAll(segmentBytes);
    for (var segment = first; segment <= last; segment++) {
      _loadedSegments.add(segment);
      _segmentOrder.add(segment);
      _segmentBuckets[segment] = {};
    }
    for (final entry in buckets.entries) {
      final segment = DmUtils.calcSegment(entry.key * 100);
      if (segment < first || segment > last) continue;
      _buckets[entry.key] = _ordered(entry.value);
      _segmentBuckets[segment]!.add(entry.key);
      _elementCount += entry.value.length;
    }
  }

  void _trim({required int protectedSegment}) {
    while (_segmentOrder.length > 1 &&
        (_segmentOrder.length > maxSegments ||
            _buckets.length > maxBuckets ||
            _elementCount > maxElements ||
            _estimatedBytes > maxBytes)) {
      final oldest = _segmentOrder.first;
      if (oldest == protectedSegment) {
        _segmentOrder
          ..removeFirst()
          ..addLast(oldest);
        continue;
      }
      _segmentOrder.removeFirst();
      _loadedSegments.remove(oldest);
      _estimatedBytes -= _segmentBytes.remove(oldest) ?? 0;
      final buckets = _segmentBuckets.remove(oldest);
      if (buckets == null) continue;
      for (final bucket in buckets) {
        _elementCount -= _buckets.remove(bucket)?.length ?? 0;
      }
    }
  }
}
