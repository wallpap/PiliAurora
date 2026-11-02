import 'dart:async';
import 'dart:math' as math;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/timeline_range.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';

/// 来源到普通窗口的有界准备；逐帧布局预算不改变固定时间桶内的内容选择。
class DanmakuWindowCoordinator<T> {
  DanmakuWindowCoordinator({
    required this.source,
    required this.renderer,
    required this.contentOf,
    this.preparePerFrame = 4,
    this.aheadUs = 2000000,
    this.refillUs = 500000,
    this.historyUs = 10000000,
  }) : assert(
         preparePerFrame > 0 &&
             preparePerFrame <= DanmakuDisplayLimits.maxPerBatch,
       ),
       assert(aheadUs > 0 && refillUs > 0 && refillUs <= aheadUs),
       assert(historyUs >= 0) {
    _subscription = source.changes.listen(_changed);
  }

  static const _bucketUs = 100000;
  final DanmakuTimelineSource source;
  final DanmakuWindowRenderer<T> renderer;
  final DanmakuContentItem<T>? Function(DanmakuElem) contentOf;
  final int preparePerFrame;
  final int aheadUs;
  final int refillUs;
  final int historyUs;
  final _updates = StreamController<void>.broadcast(sync: true);
  Stream<void> get updates => _updates.stream;
  late final StreamSubscription<DanmakuSourceChange> _subscription;
  int? _lastMediaUs;
  int _generation = -1;
  int _nextBucketUs = 0;
  int? _dirtyUs;
  List<DanmakuWindowContent<T>>? _pending;
  int _offset = 0;
  bool _pendingLoaded = false;
  bool _requesting = false;
  bool _refilling = false;
  int _targetUntilUs = 0;
  int? _lastRequestUs;
  bool _disposed = false;
  final _invalidations = <({int start, int? end, int revision})>[];
  bool requestFailed = false;
  bool _needsPreparation = false;
  bool get needsPreparation => !_disposed && _needsPreparation;
  double _effectiveRate = 1;
  int? get nextPreparationUs => _disposed || _refilling
      ? null
      : _nextBucketUs -
            (refillUs * _effectiveRate).clamp(1, 30000000).ceil() +
            1;

  void _changed(DanmakuSourceChange change) {
    if (_disposed) return;
    if (change.kind == DanmakuSourceChangeKind.coverage) {
      final range = source.readRange(
        change.startUs,
        change.endUs ?? change.startUs + _bucketUs,
        maxEntriesPerBucket: 1,
      );
      requestFailed = range.coverage.any(
        (part) => part.state == DanmakuCoverageState.failed,
      );
      if (requestFailed) _needsPreparation = false;
      _updates.add(null);
      return;
    }
    if (change.kind == DanmakuSourceChangeKind.invalidated) {
      _subtractInvalidations(change);
      _invalidations.add((
        start: change.startUs,
        end: change.endUs,
        revision: change.ruleRevision,
      ));
      renderer.invalidateRange(change.startUs, endUs: change.endUs);
    } else {
      if (_invalidations.any(
        (range) =>
            range.revision > change.ruleRevision &&
            (change.endUs == null || range.start < change.endUs!) &&
            (range.end == null || change.startUs < range.end!),
      )) {
        return;
      }
      _subtractInvalidations(change);
      final start = math.max(change.startUs, renderer.validFromUs);
      if (start < _nextBucketUs &&
          (change.endUs == null || change.endUs! > renderer.validFromUs)) {
        final bucket = start ~/ _bucketUs * _bucketUs;
        _dirtyUs = _dirtyUs == null ? bucket : math.min(_dirtyUs!, bucket);
      }
    }
    _pending = null;
    _updates.add(null);
  }

  // ready 消除失效区间，invalidated 替换重叠区间；两者保留相同的左右残段。
  void _subtractInvalidations(DanmakuSourceChange change) {
    final remaining = <({int start, int? end, int revision})>[];
    for (final range in _invalidations) {
      if ((change.endUs != null && range.start >= change.endUs!) ||
          (range.end != null && range.end! <= change.startUs)) {
        remaining.add(range);
        continue;
      }
      if (range.start < change.startUs) {
        remaining.add((
          start: range.start,
          end: change.startUs,
          revision: range.revision,
        ));
      }
      if (change.endUs != null &&
          (range.end == null || range.end! > change.endUs!)) {
        remaining.add((
          start: change.endUs!,
          end: range.end,
          revision: range.revision,
        ));
      }
    }
    _invalidations
      ..clear()
      ..addAll(remaining);
  }

  Future<void> _request(int fromUs, int untilUs) async {
    _requesting = true;
    try {
      await source.ensureRange(fromUs, untilUs);
      requestFailed = source
          .readRange(
            fromUs,
            untilUs,
            maxEntriesPerBucket: 1,
          )
          .coverage
          .any((part) => part.state == DanmakuCoverageState.failed);
    } catch (_) {
      requestFailed = true;
    } finally {
      _requesting = false;
      if (!_disposed) _updates.add(null);
    }
  }

  void prepareFrame(
    DanmakuWindowRenderer<T> target,
    int mediaUs, {
    double effectiveRate = 1,
  }) {
    if (_disposed || !identical(target, renderer)) return;
    if (!effectiveRate.isFinite || effectiveRate <= 0) {
      throw ArgumentError.value(effectiveRate, 'effectiveRate');
    }
    // 时间余量按真实时间维持，窗口条目/字节及逐帧布局预算优先。
    final mediaAheadUs = (aheadUs * effectiveRate).clamp(1, 30000000).ceil();
    final mediaRefillUs = (refillUs * effectiveRate)
        .clamp(1, mediaAheadUs)
        .ceil();
    if (_effectiveRate != effectiveRate) {
      _effectiveRate = effectiveRate;
      _refilling = false;
    }
    _needsPreparation = false;
    if (_lastMediaUs != null &&
        mediaUs - _lastMediaUs! > mediaAheadUs &&
        (mediaUs < renderer.validFromUs || mediaUs >= renderer.validUntilUs)) {
      renderer.reset(mediaUs);
    }
    _lastMediaUs = mediaUs;
    if (_generation != renderer.generation) {
      _generation = renderer.generation;
      _nextBucketUs = renderer.validFromUs ~/ _bucketUs * _bucketUs;
      _pending = null;
      _dirtyUs = null;
      _refilling = false;
      if (!_requesting) _lastRequestUs = null;
    }
    final cutoff = math.min(
      renderer.validUntilUs,
      math.max(0, mediaUs - historyUs),
    );
    if (cutoff > renderer.validFromUs) renderer.trimBefore(cutoff);
    _invalidations.removeWhere(
      (range) => range.end != null && range.end! <= renderer.validFromUs,
    );
    if (_dirtyUs != null) {
      _nextBucketUs = math.min(_nextBucketUs, _dirtyUs!);
      _dirtyUs = null;
      _pending = null;
      _refilling = true;
      _targetUntilUs = math.max(_targetUntilUs, mediaUs + mediaAheadUs);
    }
    if (!_refilling) {
      if (_pending == null && _nextBucketUs - mediaUs >= mediaRefillUs) return;
      _refilling = true;
      _targetUntilUs = mediaUs + mediaAheadUs;
    }
    if (!_requesting &&
        (_lastRequestUs == null ||
            (mediaUs - _lastRequestUs!).abs() >= _bucketUs)) {
      _lastRequestUs = mediaUs;
      unawaited(_request(mediaUs, _targetUntilUs));
    }
    final untilUs = _targetUntilUs;
    var remaining = preparePerFrame;
    var buckets = 0;
    while (remaining > 0 && _nextBucketUs < untilUs && buckets++ < 4) {
      final endUs = _nextBucketUs + _bucketUs;
      if (_pending == null) {
        final blocked = _invalidations.any(
          (range) =>
              range.start < endUs &&
              (range.end == null || range.end! > _nextBucketUs),
        );
        final range = source.readRange(
          _nextBucketUs,
          endUs,
          maxEntriesPerBucket: DanmakuDisplayLimits.maxPerBatch,
        );
        if (!range.isLoaded && range.entries.isEmpty) return;
        _pendingLoaded = range.isLoaded && !blocked;
        final occurrences = <Object, int>{};
        final eligible = range.entries
            .where(
              (entry) =>
                  entry.positionUs >= renderer.validFromUs &&
                  !range.coverage.any(
                    (part) =>
                        part.state == DanmakuCoverageState.invalidated &&
                        entry.positionUs >= part.startUs &&
                        entry.positionUs < part.endUs,
                  ) &&
                  !_invalidations.any(
                    (range) =>
                        entry.positionUs >= range.start &&
                        (range.end == null || entry.positionUs < range.end!),
                  ),
            )
            .toList();
        final count = math.min(
          eligible.length,
          DanmakuDisplayLimits.maxPerBatch,
        );
        final candidates = <DanmakuWindowContent<T>>[];
        var specials = 0;
        for (var index = 0; index < count; index++) {
          final entry = eligible[index * eligible.length ~/ count];
          final element = entry.element;
          if (element.mode == 7 &&
              ++specials > DanmakuDisplayLimits.maxSpecialPerBatch) {
            continue;
          }
          final key = (
            element.idStr,
            element.id,
            element.progress,
            element.mode,
            element.midHash,
            element.content,
          );
          final ordinal = occurrences.update(
            key,
            (value) => value + 1,
            ifAbsent: () => 0,
          );
          final identity = (key, ordinal);
          if (renderer.hasPrepared(identity)) continue;
          final content = contentOf(element);
          if (content != null) {
            candidates.add(
              DanmakuWindowContent(identity, entry.positionUs, content),
            );
          }
        }
        _pending = candidates;
        _offset = 0;
      }
      final pending = _pending!;
      final end = math.min(_offset + remaining, pending.length);
      final complete = end == pending.length;
      final frontier = complete
          ? (_pendingLoaded ? endUs : renderer.validUntilUs)
          : pending[end].sourceUs;
      if (!renderer.prepare(
        pending.sublist(_offset, end),
        generation: _generation,
        preparedUntilUs: math.max(renderer.validUntilUs, frontier),
      )) {
        return;
      }
      remaining -= end - _offset;
      _offset = end;
      if (!complete) {
        _needsPreparation = true;
        return;
      }
      _pending = null;
      if (!_pendingLoaded) return;
      _nextBucketUs = endUs;
    }
    if (_nextBucketUs >= untilUs && _pending == null) _refilling = false;
    _needsPreparation = _refilling;
  }

  void dispose() {
    _disposed = true;
    _pending = null;
    unawaited(_subscription.cancel());
    unawaited(_updates.close());
  }
}
