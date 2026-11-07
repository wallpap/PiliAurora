import 'dart:async';
import 'dart:collection';
import 'dart:io' show File;

import 'package:pili_aurora/services/danmaku/work_quota.dart';

import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/grpc/dm.dart';
import 'package:pili_aurora/pages/danmaku/cache.dart';
import 'package:pili_aurora/pages/danmaku/priority.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart' show DanmakuDisplayLimits;
import 'package:pili_aurora/pages/danmaku/file_reader.dart';
import 'package:pili_aurora/pages/danmaku/file_store.dart';
import 'package:pili_aurora/pages/danmaku/raw_cache.dart';
import 'package:pili_aurora/pages/danmaku/processing_rules.dart';
import 'package:pili_aurora/pages/danmaku/timeline_range.dart';
import 'package:pili_aurora/pages/danmaku/merge.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/danmaku_utils.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:path/path.dart' as path;

class PlDanmakuController implements DanmakuTimelineSource {
  PlDanmakuController(
    this._cid,
    this._plPlayerController,
    this._isFileSource, {
    DanmakuRawCache? rawCache,
  }) : _mergeDanmaku = _plPlayerController.mergeDanmaku,
       _rawSegments = rawCache ?? DanmakuRawCache() {
    _quotaSubscription = DanmakuWorkQuota.instance.available.listen((_) {
      if (_disposed) return;
      if (_retryFile) {
        _retryFile = false;
        initFileDmIfNeeded();
      }
      if (_retryRange) {
        _retryRange = false;
        unawaited(_scheduleRangeTarget());
      }
      if (_retryProcessing) {
        _retryProcessing = false;
        unawaited(_scheduleReprocess());
      }
    });
    _unregisterDiagnostics = Diagnostics.instance.register(
      'danmaku.$hashCode',
      () => {
        'elements': _cache.elementCount,
        'processedEstimatedBytes': _cache.estimatedBytes,
        'processedByteLimit': _cache.maxBytes,
        'rawSegments': _rawSegments.length,
        'rawEstimatedBytes': _rawSegments.estimatedBytes,
        'processWorkQuota': DanmakuWorkQuota.instance.snapshot,
        'buckets': _cache.bucketCount,
        'pendingSegments': _requestedSeg.length,
        'localFile': _isFileSource,
        'frameRate': Pref.danmakuFrameRate,
        'enabled': _plPlayerController.enableShowDanmaku.value,
      },
    );
  }

  late final void Function() _unregisterDiagnostics;
  late final StreamSubscription<void> _quotaSubscription;
  bool _retryProcessing = false;
  bool _retryFile = false;
  bool _retryRange = false;

  final int _cid;
  final PlPlayerController _plPlayerController;
  bool _mergeDanmaku;
  final bool _isFileSource;

  late final _isLogin = Accounts.main.isLogin;

  final _cache = DanmakuCache();
  // 请求中的分段单独记录；成功加载后由缓存记录，淘汰后允许重新请求。
  final Set<int> _requestedSeg = HashSet();
  bool _disposed = false;
  final _lifetimeWork = DanmakuWorkToken();
  var _ruleWork = DanmakuWorkToken();

  final _changes = StreamController<DanmakuSourceChange>.broadcast(sync: true);
  @override
  Stream<DanmakuSourceChange> get changes => _changes.stream;
  final DanmakuRawCache _rawSegments;
  List<DanmakuElem>? _rawFile;
  int _ruleRevision = 0;
  final _invalidatedSegments = <int>{};
  bool _fileInvalidated = false;
  bool _fileLoading = false;
  bool _fileFailed = false;
  final _failedSegments = <int>{};
  final _orderedFile = OrderedDanmakuFileStore();
  bool _fileKnown = false;
  Future<void>? _reprocessing;
  ({int first, int last})? _rangeTarget;
  Future<void>? _rangeProcessing;
  ({int first, int last}) _fileDesired = (first: 0, last: 0);
  var _fileWork = DanmakuWorkToken();
  Future<void>? _fileProcessing;

  /// 接受规则时先同步失效；重算仅提交当前修订的结果。
  Future<void> refreshRules() {
    if (_disposed) return Future.value();
    _ruleWork.cancel();
    _fileWork.cancel();
    _fileWork = DanmakuWorkToken();
    _ruleWork = DanmakuWorkToken();
    _ruleRevision++;
    _mergeDanmaku = _plPlayerController.mergeDanmaku;
    _cache.clear();
    _failedSegments.clear();
    _fileFailed = false;
    _invalidatedSegments
      ..clear()
      ..addAll(_rawSegments.keys);
    _fileInvalidated = _isFileSource;
    _changes.add(
      DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.invalidated,
        ruleRevision: _ruleRevision,
      ),
    );
    return _scheduleReprocess();
  }

  Future<void> _scheduleReprocess() {
    return _reprocessing ??= _reprocess().whenComplete(
      () => _reprocessing = null,
    );
  }

  Future<void> _reprocess() async {
    var revision = -1;
    while (!_disposed && revision != _ruleRevision) {
      revision = _ruleRevision;
      if (_isFileSource) {
        final raw = _rawFile;
        if (raw != null) {
          await handleDanmaku(raw);
        } else {
          await _scheduleFileRange();
        }
      } else {
        for (final segment in _rawSegments.keys.toList()) {
          if (_disposed || revision != _ruleRevision) break;
          final raw = _rawSegments[segment];
          if (raw != null) await handleDanmaku(raw, segmentIndex: segment);
        }
      }
    }
  }

  void dispose() {
    _unregisterDiagnostics();
    _disposed = true;
    unawaited(_quotaSubscription.cancel());
    _lifetimeWork.cancel();
    _ruleWork.cancel();
    _fileWork.cancel();
    unawaited(_orderedFile.dispose());
    _cache.clear();
    _requestedSeg.clear();
    _rawSegments.clear();
    _rawFile = null;
    _rangeTarget = null;
    _invalidatedSegments.clear();
    unawaited(_changes.close());
  }

  Future<void> queryDanmaku(int segmentIndex) async {
    if (_isFileSource || _disposed) {
      return;
    }
    if (_invalidatedSegments.contains(segmentIndex) &&
        _rawSegments[segmentIndex] != null) {
      await _scheduleReprocess();
      return;
    }
    if (_requestedSeg.length >= _cache.maxSegments ||
        _requestedSeg.contains(segmentIndex) ||
        _cache.containsSegment(segmentIndex)) {
      return;
    }
    if (!DanmakuWorkQuota.instance.hasWaitingCapacity) {
      _rangeTarget ??= (first: segmentIndex, last: segmentIndex);
      _retryRange = true;
      return;
    }
    _requestedSeg.add(segmentIndex);
    _failedSegments.remove(segmentIndex);
    _coverageChanged(segmentIndex);
    try {
      final response = await DmGrpc.dmSegMobile(
        cid: _cid,
        segmentIndex: segmentIndex + 1,
        workToken: _lifetimeWork,
        consume: (response, lease) async {
          if (_disposed) return;
          if (response.state == 1) _plPlayerController.dmState.add(_cid);
          await handleDanmaku(
            response.elems,
            segmentIndex: segmentIndex,
            lease: lease,
          );
        },
      );
      if (!_disposed && !response.isSuccess) _failedSegments.add(segmentIndex);
    } catch (_) {
      if (!_disposed) _failedSegments.add(segmentIndex);
    } finally {
      _requestedSeg.remove(segmentIndex);
      _coverageChanged(segmentIndex);
    }
  }

  void _coverageChanged([int? segment]) {
    if (_disposed) return;
    _changes.add(
      DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.coverage,
        ruleRevision: _ruleRevision,
        startUs: segment == null
            ? _fileDesired.first * 360000000
            : segment * 360000000,
        endUs: segment == null
            ? (_fileDesired.last + 1) * 360000000
            : (segment + 1) * 360000000,
      ),
    );
  }

  Future<void> handleDanmaku(
    List<DanmakuElem> elems, {
    int? segmentIndex,
    DanmakuWorkLease? lease,
  }) async {
    if (_disposed) return;
    if (_isFileSource) {
      _rawFile = elems;
    } else if (segmentIndex != null) {
      _rawSegments.retain(segmentIndex, elems);
      _invalidatedSegments.removeWhere(
        (segment) => _rawSegments[segment] == null,
      );
    }
    try {
      if (lease != null) {
        await lease.execute(
          () => _processDanmaku(
            elems,
            segmentIndex,
            lease,
            inputAlreadyReserved: true,
          ),
        );
      } else {
        await DanmakuWorkQuota.instance.runWithLease(
          estimateDanmakuWorkBytes(elems),
          (lease) => _processDanmaku(elems, segmentIndex, lease),
          token: _ruleWork,
          waitingBytes: estimateDanmakuInputBytes(elems) + 256,
        );
      }
    } on DanmakuWorkBusy {
      _retryProcessing = true;
    } on DanmakuWorkCancelled {
      return;
    } on DanmakuWorkTooLarge {
      if (_isFileSource) {
        _fileFailed = true;
      } else if (segmentIndex != null) {
        _failedSegments.add(segmentIndex);
      }
      _coverageChanged(segmentIndex);
    }
  }

  Future<void> _processDanmaku(
    List<DanmakuElem> elems,
    int? segmentIndex,
    DanmakuWorkLease lease, {
    bool inputAlreadyReserved = false,
  }) async {
    if (_disposed) return;
    final revision = _ruleRevision;
    final workToken = _ruleWork;
    final retained = _isFileSource ? <DanmakuElem>[] : null;
    final segmentBuckets = segmentIndex == null
        ? null
        : <int, List<DanmakuElem>>{};

    final rules = DanmakuProcessingRules(
      merge: _mergeDanmaku,
      fileSource: _isFileSource,
      segmentIndex: segmentIndex,
      selfHash: _isLogin ? _plPlayerController.midHash : null,
      filter: _plPlayerController.filters,
    );
    final List<DanmakuElem> processed;
    try {
      processed = await processDanmakuInBackground(
        elems,
        rules: rules,
        lease: lease,
        token: workToken,
        inputAlreadyReserved: inputAlreadyReserved,
      );
    } on DanmakuWorkCancelled {
      return;
    }
    if (_disposed || revision != _ruleRevision) return;
    for (final element in processed) {
      if (_isFileSource) {
        retained!.add(element);
      } else {
        final bucketIndex = element.progress ~/ 100;
        (segmentBuckets![bucketIndex] ??= <DanmakuElem>[]).add(element);
      }
    }
    if (_isFileSource) {
      // 本地文件无法回源，保留完整弹幕。
      _cache.addFileElements(retained!);
      _fileInvalidated = false;
    } else if (segmentIndex != null) {
      _cache.addSegmentBuckets(segmentIndex, segmentBuckets!);
      if (!_cache.containsSegment(segmentIndex)) {
        _failedSegments.add(segmentIndex);
        _coverageChanged(segmentIndex);
        return;
      }
      _failedSegments.remove(segmentIndex);
      _invalidatedSegments.remove(segmentIndex);
    }
    _changes.add(
      DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.ready,
        ruleRevision: revision,
        startUs: segmentIndex == null ? 0 : segmentIndex * 360000000,
        endUs: segmentIndex == null ? null : (segmentIndex + 1) * 360000000,
      ),
    );
  }

  List<DanmakuElem>? getCurrentDanmaku(int progress) {
    if (_isFileSource) {
      unawaited(ensureRange(progress * 1000, (progress + 100) * 1000));
    } else {
      final int segmentIndex = DmUtils.calcSegment(progress);
      if (!_requestedSeg.contains(segmentIndex) &&
          !_cache.containsSegment(segmentIndex)) {
        queryDanmaku(segmentIndex);
        return null;
      }
    }
    return _cache.getAt(progress);
  }

  @override
  Future<void> ensureRange(int startUs, int endUs) async {
    if (startUs < 0 || endUs < startUs) throw ArgumentError('弹幕请求范围无效');
    if (_disposed || startUs == endUs) return;
    if (_isFileSource) {
      const segmentUs = DmUtils.segLength * 1000;
      final first = startUs ~/ segmentUs;
      final last = ((endUs - 1) ~/ segmentUs).clamp(
        first,
        first + _cache.maxSegments - 1,
      );
      final desired = (first: first, last: last);
      if (_fileDesired != desired) {
        _fileDesired = desired;
        _fileWork.cancel();
        _fileWork = DanmakuWorkToken();
      }
      await _scheduleFileRange();
      return;
    }
    const segmentUs = DmUtils.segLength * 1000;
    final first = startUs ~/ segmentUs;
    final last = ((endUs - 1) ~/ segmentUs).clamp(
      first,
      first + _cache.maxSegments - 1,
    );
    // 等待期间覆盖描述；当前批次完成后从最新画面开始，旧前瞻不积压。
    _failedSegments.removeWhere((segment) => segment < first || segment > last);
    _rangeTarget = (first: first, last: last);
    await _scheduleRangeTarget();
  }

  Future<void> _scheduleRangeTarget() =>
      _rangeProcessing ??= Future<void>.microtask(_processRangeTarget)
          .whenComplete(
            () => _rangeProcessing = null,
          );

  Future<void> _processRangeTarget() async {
    while (!_disposed && _rangeTarget != null) {
      final target = _rangeTarget!;
      _rangeTarget = null;
      for (var segment = target.first; segment <= target.last; segment++) {
        if (_disposed || _rangeTarget != null) break;
        if (!DanmakuWorkQuota.instance.hasWaitingCapacity) {
          _rangeTarget ??= target;
          _retryRange = true;
          return;
        }
        await queryDanmaku(segment);
      }
    }
  }

  @override
  DanmakuTimelineRange readRange(
    int startUs,
    int endUs, {
    int? maxEntriesPerBucket,
  }) => _cache.readRange(
    startUs,
    endUs,
    ruleRevision: _ruleRevision,
    maxEntriesPerBucket: maxEntriesPerBucket,
    missingState: (segment) {
      if (_isFileSource ? _fileFailed : _failedSegments.contains(segment)) {
        return DanmakuCoverageState.failed;
      }
      if (_isFileSource
          ? _fileLoading &&
                segment >= _fileDesired.first &&
                segment <= _fileDesired.last
          : _requestedSeg.contains(segment)) {
        return DanmakuCoverageState.loading;
      }
      if (_fileInvalidated || _invalidatedSegments.contains(segment)) {
        return DanmakuCoverageState.invalidated;
      }
      return DanmakuCoverageState.missing;
    },
  );

  Iterable<DanmakuElem> peekBufferedDanmaku(int start, int end) => readRange(
    start * 1000,
    end * 1000,
  ).entries.take(64).map((entry) => entry.element);

  void initFileDmIfNeeded() {
    unawaited(_scheduleFileRange());
  }

  Future<void> _scheduleFileRange() =>
      _fileProcessing ??= Future<void>.microtask(_initFileDm).whenComplete(
        () => _fileProcessing = null,
      );

  @pragma('vm:notify-debugger-on-exception')
  Future<void> _initFileDm() async {
    try {
      final fileSource = _plPlayerController.currentFileSource;
      if (fileSource == null) return;
      final file = File(
        path.join(
          fileSource.dir,
          PathUtils.danmakuName,
        ),
      );
      if (await _orderedFile.updateSource(file)) {
        if (_fileKnown) {
          _invalidateFile();
        } else {
          _cache.clear();
          _fileInvalidated = true;
          _fileKnown = true;
        }
      }
      _fileFailed = false;
      _fileLoading = true;
      _coverageChanged();
      while (!_disposed) {
        final desired = _fileDesired;
        final revision = _ruleRevision;
        if (!_fileInvalidated &&
            [for (var i = desired.first; i <= desired.last; i++) i]
                .every(_cache.containsSegment)) {
          return;
        }
        final token = _fileWork;
        try {
          await DanmakuWorkQuota.instance.runWithLease(
            DanmakuWorkQuota.instance.maxBytes,
            (lease) => _processFileRange(
              file,
              desired.first,
              desired.last,
              revision,
              token,
              lease,
            ),
            token: token,
          );
        } on DanmakuWorkCancelled {
          if (_disposed) return;
          if (!token.isCancelled) {
            _invalidateFile();
            continue;
          }
        } catch (_) {
          if (desired != _fileDesired || revision != _ruleRevision) continue;
          rethrow;
        }
        if (desired == _fileDesired && revision == _ruleRevision) return;
      }
    } on DanmakuWorkBusy {
      _retryFile = true;
    } on DanmakuWorkCancelled {
      return;
    } catch (e, s) {
      if (!_disposed) {
        _fileFailed = true;
        _invalidateFile();
      }
      Utils.reportError(e, s);
    } finally {
      _fileLoading = false;
      _coverageChanged();
    }
  }

  void _invalidateFile() {
    _cache.clear();
    _fileInvalidated = true;
    _ruleRevision++;
    _changes.add(
      DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.invalidated,
        ruleRevision: _ruleRevision,
      ),
    );
  }

  Future<void> _processFileRange(
    File file,
    int first,
    int last,
    int revision,
    DanmakuWorkToken token,
    DanmakuWorkLease lease,
  ) async {
    final rules = DanmakuProcessingRules(
      merge: _mergeDanmaku,
      fileSource: true,
      selfHash: _isLogin ? _plPlayerController.midHash : null,
      filter: _plPlayerController.filters,
    );
    final start = first * DmUtils.segLength;
    final end = (last + 1) * DmUtils.segLength;
    final retained = DanmakuPriorityRetention(
      maxElements: _cache.maxElements,
      maxPerBucket: DanmakuDisplayLimits.maxPerBatch,
      maxBytes: _cache.maxBytes,
      baseBytes: (last - first + 1) * DanmakuCache.segmentIndexBytes,
    );
    var index = 0;
    Stream<List<DanmakuElem>> batches() async* {
      final input = rules.merge
          ? _orderedFile.read(file, token: token)
          : readDanmakuFile(file, token: token);
      await for (final batch in input) {
        if (rules.merge &&
            batch.first.progress >= end + DanmakuMerger.windowMilliseconds) {
          break;
        }
        yield batch;
      }
    }

    const resultBytes = DanmakuCache.defaultMaxBytes;
    // 结果对象与 retained/buckets 两组索引在 worker 运行期间共同持有。
    final resultReservation = resultBytes + _cache.maxElements * 256;
    final pipelineLease = lease.retaining(
      resultReservation + orderedDanmakuFileWorkBytes,
    );
    await processOrderedDanmakuBatches(
      batches(),
      rules: rules,
      lease: pipelineLease,
      token: token,
      consume: (delta) {
        for (final element in delta.additions) {
          final outputIndex = index++;
          if (element.progress < start || element.progress >= end) continue;
          retained.add(outputIndex, element);
        }
        for (final update in delta.promotions.entries) {
          if (update.value.progress >= start && update.value.progress < end) {
            retained.promote(update.key, update.value);
          }
        }
        for (final update in delta.counts.entries) {
          retained.update(update.key, count: update.value);
        }
      },
    );
    if (_disposed || token.isCancelled || revision != _ruleRevision) return;
    if (await _orderedFile.updateSource(file)) {
      throw const DanmakuWorkCancelled();
    }
    if (_disposed || token.isCancelled || revision != _ruleRevision) return;
    _cache.replaceFileRange(first, last, retained.buckets);
    _fileInvalidated = false;
    _changes.add(
      DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.ready,
        ruleRevision: revision,
        startUs: start * 1000,
        endUs: end * 1000,
      ),
    );
  }
}
