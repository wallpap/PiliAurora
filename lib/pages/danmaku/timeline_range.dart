import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';

/// 来源接入处将服务端毫秒转换为媒体微秒。
class DanmakuTimelineEntry {
  const DanmakuTimelineEntry(this.element, {this.localPositionUs});

  final DanmakuElem element;
  final int? localPositionUs;
  int get positionUs =>
      localPositionUs ?? element.progress * Duration.microsecondsPerMillisecond;
}

enum DanmakuCoverageState { loaded, missing, loading, invalidated, failed }

class DanmakuRangeCoverage {
  const DanmakuRangeCoverage(this.startUs, this.endUs, this.state);

  final int startUs;
  final int endUs;
  final DanmakuCoverageState state;
}

/// 半开范围 [startUs, endUs) 的来源快照；读取不改变缓存淘汰顺序。
class DanmakuTimelineRange {
  DanmakuTimelineRange({
    required this.startUs,
    required this.endUs,
    required this.revision,
    this.ruleRevision = 0,
    required Iterable<DanmakuTimelineEntry> entries,
    required Iterable<DanmakuRangeCoverage> coverage,
  }) : entries = List.unmodifiable(entries),
       coverage = List.unmodifiable(coverage);

  final int startUs;
  final int endUs;
  final int revision;
  final int ruleRevision;
  final List<DanmakuTimelineEntry> entries;
  final List<DanmakuRangeCoverage> coverage;

  bool get isLoaded => coverage.every(
    (range) => range.state == DanmakuCoverageState.loaded,
  );
}

enum DanmakuSourceChangeKind { invalidated, ready, coverage }

class DanmakuSourceChange {
  const DanmakuSourceChange({
    required this.kind,
    required this.ruleRevision,
    this.startUs = 0,
    this.endUs,
  });

  final DanmakuSourceChangeKind kind;
  final int ruleRevision;
  final int startUs;

  /// null 表示整个来源，包括已离开当前读取范围的内容。
  final int? endUs;
}

abstract interface class DanmakuTimelineSource {
  Stream<DanmakuSourceChange> get changes;

  /// 按媒体时间和来源次序读取；各 100 ms 桶的范围交集优先保留自己发送及高权重项，
  /// 覆盖状态仍描述完整请求范围。
  DanmakuTimelineRange readRange(
    int startUs,
    int endUs, {
    int? maxEntriesPerBucket,
  });
  Future<void> ensureRange(int startUs, int endUs);
}
