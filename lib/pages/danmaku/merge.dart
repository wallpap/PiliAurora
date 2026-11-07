import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/services/danmaku/work_quota.dart';
import 'package:pili_aurora/pages/danmaku/element_size.dart';
import 'package:pili_aurora/pages/danmaku/processing_rules.dart';

int estimateDanmakuInputBytes(List<DanmakuElem> elements) =>
    64 +
    8 * elements.length +
    elements.fold<int>(
      0,
      (bytes, element) => bytes + estimateDanmakuElementBytes(element),
    );

/// 输入与结果、排序双索引及有界 worker；解码租约已保留的输入不重复预约。
int estimateDanmakuWorkBytes(
  List<DanmakuElem> elements, {
  bool inputAlreadyReserved = false,
}) =>
    (inputAlreadyReserved ? 1 : 2) *
        elements.fold<int>(
          0,
          (bytes, element) => bytes + estimateDanmakuElementBytes(element),
        ) +
    32 * elements.length +
    orderedDanmakuWorkerBytes;

/// 批次发送方、worker 输入与返回、接收方引用；游标另行持有跨批上下文。
const orderedDanmakuWorkerBytes =
    DanmakuProcessingBudget.cursorBytes +
    DanmakuProcessingBudget.groupBytes + // 权重提升时返回的代表项，最坏为整个合并组。
    DanmakuProcessingBudget.normalizationScratchBytes +
    4 * DanmakuProcessingBudget.batchBytes +
    2 * DanmakuProcessingBudget.rulesBytes +
    256 * 64;

/// 分段与文件合并共用后台路径，已获配批次沿用其处理预留。
Future<List<DanmakuElem>> mergeDanmakuInBackground(
  List<DanmakuElem> elements, {
  DanmakuWorkToken? token,
  DanmakuWorkLease? lease,
}) {
  return processDanmakuInBackground(
    elements,
    rules: DanmakuProcessingRules(),
    token: token,
    lease: lease,
  );
}

Future<List<DanmakuElem>> processDanmakuInBackground(
  List<DanmakuElem> elements, {
  required DanmakuProcessingRules rules,
  DanmakuWorkToken? token,
  DanmakuWorkLease? lease,
  bool inputAlreadyReserved = false,
}) {
  Future<List<DanmakuElem>> merge() {
    lease?.requireBytes(
      estimateDanmakuWorkBytes(
        elements,
        inputAlreadyReserved: inputAlreadyReserved,
      ),
    );
    return _mergeInWorker(elements, token, rules);
  }

  return lease != null
      ? lease.execute(merge)
      : DanmakuWorkQuota.instance.run(
          estimateDanmakuWorkBytes(elements),
          merge,
          token: token,
          waitingBytes:
              estimateDanmakuInputBytes(elements) + rules.storageBytes + 256,
        );
}

const _mergeBatchElements = DanmakuProcessingBudget.batchElements;
const _mergeBatchBytes = DanmakuProcessingBudget.batchBytes;

/// 已按来源稳定次序排序的文件批次，共用一个游标；接收方按范围转移结果。
Future<void> processOrderedDanmakuBatches(
  Stream<List<DanmakuElem>> batches, {
  required DanmakuProcessingRules rules,
  required void Function(DanmakuMergeDelta) consume,
  required DanmakuWorkLease lease,
  DanmakuWorkToken? token,
}) => lease.execute(() async {
  lease.requireBytes(orderedDanmakuWorkerBytes);
  rules.requireBudget();
  final output = ReceivePort();
  final events = StreamIterator<dynamic>(output);
  Isolate? worker;
  SendPort? input;
  var exited = false;
  Future<dynamic> next() async {
    if (!await events.moveNext()) throw StateError('弹幕处理通道已关闭');
    final event = events.current;
    if (event == null) {
      exited = true;
      throw StateError('弹幕处理 worker 提前退出');
    }
    if (event is DanmakuWorkTooLarge) throw event;
    if (event is List) throw StateError('弹幕处理 worker 执行失败');
    return event;
  }

  try {
    worker = await Isolate.spawn(
      _mergeWorker,
      (output.sendPort, rules),
      onError: output.sendPort,
      onExit: output.sendPort,
    );
    input = await next() as SendPort;
    await for (final batch in batches) {
      if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
      _requireBatch(batch);
      input.send(batch);
      consume(await next() as DanmakuMergeDelta);
    }
    if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
  } finally {
    input?.send(null);
    if (worker != null && !exited) {
      while (await events.moveNext()) {
        if (events.current == null) break;
      }
    }
    await events.cancel();
    output.close();
  }
});

void _requireBatch(List<DanmakuElem> batch) {
  if (batch.length > _mergeBatchElements) {
    throw DanmakuWorkTooLarge(batch.length, _mergeBatchElements);
  }
  final bytes = batch.fold<int>(
    0,
    (sum, element) => sum + estimateDanmakuElementBytes(element),
  );
  if (bytes > _mergeBatchBytes) {
    throw DanmakuWorkTooLarge(bytes, _mergeBatchBytes);
  }
}

void _mergeWorker((SendPort, DanmakuProcessingRules) request) {
  final (output, rules) = request;
  final input = ReceivePort();
  final cursor = DanmakuMergeCursor();
  output.send(input.sendPort);
  input.listen((message) {
    if (message == null) {
      input.close();
    } else {
      try {
        final filtered = (message as List<DanmakuElem>)
            .where(rules.retain)
            .toList();
        output.send(
          rules.merge
              ? cursor.appendDelta(filtered)
              : DanmakuMergeDelta(filtered, const {}),
        );
      } on DanmakuWorkTooLarge catch (error) {
        output.send(error);
        input.close();
      }
    }
  });
}

Future<List<int>> _orderedIndices(
  List<DanmakuElem> elements,
  DanmakuWorkToken? token,
) async {
  var order = List.generate(elements.length, (index) => index);
  int compare(int a, int b) {
    final time = elements[a].progress.compareTo(elements[b].progress);
    return time == 0 ? a.compareTo(b) : time;
  }

  for (var start = 0; start < order.length; start += _mergeBatchElements) {
    final end = math.min(start + _mergeBatchElements, order.length);
    final run = order.sublist(start, end)..sort(compare);
    order.setRange(start, end, run);
    await Future<void>.delayed(Duration.zero);
    if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
  }
  var buffer = List<int>.filled(order.length, 0);
  for (var width = _mergeBatchElements; width < order.length; width *= 2) {
    var processed = 0;
    for (var start = 0; start < order.length; start += width * 2) {
      final middle = math.min(start + width, order.length);
      final end = math.min(start + width * 2, order.length);
      var left = start;
      var right = middle;
      for (var target = start; target < end; target++) {
        buffer[target] =
            right >= end ||
                (left < middle && compare(order[left], order[right]) <= 0)
            ? order[left++]
            : order[right++];
        if (++processed % 4096 == 0) {
          await Future<void>.delayed(Duration.zero);
          if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
        }
      }
    }
    final previous = order;
    order = buffer;
    buffer = previous;
  }
  return order;
}

Future<List<DanmakuElem>> _mergeInWorker(
  List<DanmakuElem> elements,
  DanmakuWorkToken? token,
  DanmakuProcessingRules rules,
) async {
  if (elements.isEmpty) return [];
  rules.requireBudget();
  // 仅排序来源索引；protobuf 对象按有界批次复制到 worker。
  final order = rules.merge
      ? await _orderedIndices(elements, token)
      : List.generate(elements.length, (index) => index);
  final output = ReceivePort();
  final events = StreamIterator<dynamic>(output);
  Isolate? worker;
  SendPort? input;
  var exited = false;
  Future<dynamic> next() async {
    if (!await events.moveNext()) throw StateError('弹幕合并 worker 通道已关闭');
    final event = events.current;
    if (event == null) {
      exited = true;
      throw StateError('弹幕合并 worker 提前退出');
    }
    if (event is DanmakuWorkTooLarge) throw event;
    if (event is List) throw StateError('弹幕合并 worker 执行失败');
    return event;
  }

  try {
    worker = await Isolate.spawn(
      _mergeWorker,
      (output.sendPort, rules),
      onError: output.sendPort,
      onExit: output.sendPort,
    );
    input = await next() as SendPort;
    final result = <DanmakuElem>[];
    var start = 0;
    while (start < order.length) {
      if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
      final batch = <DanmakuElem>[];
      var bytes = 0;
      while (start < order.length && batch.length < _mergeBatchElements) {
        final element = elements[order[start]];
        final size = estimateDanmakuElementBytes(element);
        if (size > _mergeBatchBytes) {
          throw DanmakuWorkTooLarge(size, _mergeBatchBytes);
        }
        if (batch.isNotEmpty && bytes + size > _mergeBatchBytes) break;
        batch.add(element);
        bytes += size;
        start++;
      }
      input.send(batch);
      final delta = await next() as DanmakuMergeDelta;
      result.addAll(delta.additions);
      for (final update in delta.promotions.entries) {
        result[update.key].weight = update.value.weight;
      }
      for (final update in delta.counts.entries) {
        result[update.key].count = update.value;
      }
    }
    if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
    return result;
  } finally {
    input?.send(null);
    // 配额一直保留到 worker 的真实退出通知。
    if (worker != null && !exited) {
      while (await events.moveNext()) {
        if (events.current == null) break;
      }
    }
    await events.cancel();
    output.close();
  }
}

class DanmakuMergeDelta {
  const DanmakuMergeDelta(
    this.additions,
    this.counts, [
    this.promotions = const {},
  ]);
  final List<DanmakuElem> additions;
  final Map<int, int> counts;
  final Map<int, DanmakuElem> promotions;
}

/// 合并窗口以首条弹幕为锚点，避免连续刷屏把后续整段内容吞掉。
class DanmakuMerger {
  static const windowMilliseconds = 20000;
  static const _maxGroups = 2048;
  static final _punctuation = RegExp(
    r'[\s，。！？、；：,.!?;:~～…「」『』（）()【】\[\]"“”‘’]',
  );
  static final _repeated = RegExp(r'([^0-9])\1{2,}', unicode: true);
  static final _meaning = RegExp(r'[不没无别非未]|[0-9]+');

  List<DanmakuElem> merge(List<DanmakuElem> elements) {
    final ordered = elements.indexed.toList()
      ..sort((a, b) {
        final time = a.$2.progress.compareTo(b.$2.progress);
        return time == 0 ? a.$1.compareTo(b.$1) : time;
      });
    final cursor = DanmakuMergeCursor();
    final result = <DanmakuElem>[];
    for (var start = 0; start < ordered.length; start += 256) {
      final end = math.min(start + 256, ordered.length);
      result.addAll(
        cursor.appendOrdered([
          for (var index = start; index < end; index++) ordered[index].$2,
        ]),
      );
    }
    return result;
  }

  static String normalize(String text) {
    final halfWidth = String.fromCharCodes(
      text.runes.map(
        (rune) => rune >= 0xff01 && rune <= 0xff5e ? rune - 0xfee0 : rune,
      ),
    );
    final normalized = halfWidth
        .toLowerCase()
        .replaceAll(_punctuation, '')
        .replaceAllMapped(_repeated, (match) => '${match[1]}${match[1]}');
    return normalized.isEmpty ? text.trim() : normalized;
  }
}

/// 有序批次共用窗口状态。返回本批新增项；后续匹配会更新此前返回项的 count。
/// 同时间条目保持调用方顺序，每次独立重算创建新的游标。
class DanmakuMergeCursor {
  DanmakuMergeCursor({
    this.maxGroupBytes = DanmakuProcessingBudget.groupBytes,
    this.maxNormalizedBytes = DanmakuProcessingBudget.normalizedBytes,
  });
  final int maxGroupBytes;
  final int maxNormalizedBytes;
  final _groups = Queue<_MergeGroup>();
  final _exact = <(int, String), _MergeGroup>{};
  final _lengths = <(int, int), Queue<_MergeGroup>>{};
  final _normalizedTexts = <String, String>{};
  final _matcher = _DistanceMatcher();
  int _groupBytes = 0;
  int _normalizedBytes = 0;
  int get groupBytes => _groupBytes;
  int get normalizedBytes => _normalizedBytes;

  int? _lastProgress;
  int _nextIndex = 0;

  DanmakuMergeDelta appendDelta(List<DanmakuElem> elements) {
    final counts = <int, int>{};
    final promotions = <int, DanmakuElem>{};
    final additions = _appendOrdered(elements, counts, promotions);
    return DanmakuMergeDelta(additions, counts, promotions);
  }

  List<DanmakuElem> appendOrdered(List<DanmakuElem> elements) =>
      _appendOrdered(elements, null, null);

  List<DanmakuElem> _appendOrdered(
    List<DanmakuElem> elements,
    Map<int, int>? counts,
    Map<int, DanmakuElem>? promotions,
  ) {
    var previous = _lastProgress;
    for (final element in elements) {
      final bytes = estimateDanmakuElementBytes(element);
      if (bytes > _mergeBatchBytes) {
        throw DanmakuWorkTooLarge(bytes, _mergeBatchBytes);
      }
      if (element.content.length >
          DanmakuProcessingBudget.maxElementEncodedBytes) {
        throw DanmakuWorkTooLarge(
          element.content.length,
          DanmakuProcessingBudget.maxElementEncodedBytes,
        );
      }
      if (previous != null && element.progress < previous) {
        throw ArgumentError('合并批次必须沿媒体时间有序追加');
      }
      previous = element.progress;
    }
    _lastProgress = previous;
    final result = <DanmakuElem>[];
    String normalizedText(String content) {
      final cached = _normalizedTexts[content];
      if (cached != null) return cached;
      final text = DanmakuMerger.normalize(content);
      // 重复原文复用归一化结果；缓存限界，分散文本不会持续增加匹配状态。
      final bytes = 128 + 2 * (content.length + text.length);
      while (_normalizedTexts.isNotEmpty &&
          (_normalizedTexts.length >= DanmakuMerger._maxGroups ||
              _normalizedBytes + bytes > maxNormalizedBytes)) {
        final key = _normalizedTexts.keys.first;
        final value = _normalizedTexts.remove(key)!;
        _normalizedBytes -= 128 + 2 * (key.length + value.length);
      }
      if (bytes <= maxNormalizedBytes) {
        _normalizedTexts[content] = text;
        _normalizedBytes += bytes;
      }
      return text;
    }

    void evict() {
      final group = _groups.removeFirst();
      _groupBytes -= group.bytes;
      final key = (group.element.mode, group.text);
      if (identical(_exact[key], group)) _exact.remove(key);
      final lengthKey = (group.element.mode, group.runes.length);
      final candidates = _lengths[lengthKey]!..removeFirst();
      if (candidates.isEmpty) _lengths.remove(lengthKey);
    }

    for (final element in elements) {
      element.count = 1;
      // 互动池包含评分数字等普通文字弹幕，沿用普通池的合并规则。
      if (element.isSelf ||
          (element.pool != 0 && element.pool != 3) ||
          element.mode < 1 ||
          element.mode > 6) {
        result.add(element);
        _nextIndex++;
        continue;
      }
      while (_groups.isNotEmpty &&
          element.progress - _groups.first.element.progress >
              DanmakuMerger.windowMilliseconds) {
        evict();
      }
      final text = normalizedText(element.content);
      final key = (element.mode, text);
      var match = _exact[key];
      if (match != null) {
        match.element.count++;
        if (element.weight > match.element.weight) {
          match.element.weight = element.weight;
          promotions?[match.index] = match.element;
        }
        counts?[match.index] = match.element.count;
        continue;
      }
      final runes = Uint32List(text.runes.length);
      var runeIndex = 0;
      for (final rune in text.runes) {
        runes[runeIndex++] = rune;
      }
      // 语义特征每条提取一次，不随候选数量重复执行正则匹配。
      final meaning = DanmakuMerger._meaning
          .allMatches(text)
          .map((m) => m[0])
          .join();
      if (runes.length >= 8 && runes.length <= 200) {
        final distance = math.min(2, runes.length ~/ 8).clamp(1, 2);
        var checked = 0;
        search:
        for (
          var length = runes.length - distance;
          length <= runes.length + distance;
          length++
        ) {
          for (final candidate
              in _lengths[(element.mode, length)] ?? const <_MergeGroup>[]) {
            if (++checked > 64) break search;
            // 数字与否定词保留语义，避免把不同时间、比分或相反观点合并。
            if (meaning == candidate.meaning &&
                _matcher.withinDistance(runes, candidate.runes, distance)) {
              match = candidate;
              break search;
            }
          }
        }
      }
      if (match != null) {
        match.element.count++;
        if (element.weight > match.element.weight) {
          match.element.weight = element.weight;
          promotions?[match.index] = match.element;
        }
        counts?[match.index] = match.element.count;
        continue;
      }
      final group = _MergeGroup(element, text, runes, meaning, _nextIndex++);
      if (_groups.length >= DanmakuMerger._maxGroups) evict();
      if (_groupBytes + group.bytes > maxGroupBytes) {
        throw DanmakuWorkTooLarge(_groupBytes + group.bytes, maxGroupBytes);
      }
      _groupBytes += group.bytes;
      _groups.add(group);
      _exact[key] = group;
      (_lengths[(element.mode, runes.length)] ??= Queue()).add(group);
      result.add(element);
    }
    return result;
  }
}

class _DistanceMatcher {
  // 查询长度最多 200，候选可比查询长 2；另留一列存放边界哨兵。
  final _first = Uint16List(204);
  final _second = Uint16List(204);

  bool withinDistance(List<int> first, List<int> second, int limit) {
    var start = 0;
    var firstEnd = first.length;
    var secondEnd = second.length;
    // 去掉相同前后缀后再计算距离，长文本的少量差异无需扫描整段矩阵。
    while (start < firstEnd &&
        start < secondEnd &&
        first[start] == second[start]) {
      start++;
    }
    while (firstEnd > start &&
        secondEnd > start &&
        first[firstEnd - 1] == second[secondEnd - 1]) {
      firstEnd--;
      secondEnd--;
    }
    final firstLength = firstEnd - start;
    final secondLength = secondEnd - start;
    if ((firstLength - secondLength).abs() > limit) return false;
    if (firstLength == 0 || secondLength == 0) return true;

    var previous = _first;
    var current = _second;
    final infinity = limit + 1;
    final initialEnd = math.min(secondLength, limit);
    for (var j = 0; j <= initialEnd; j++) {
      previous[j] = j;
    }
    previous[initialEnd + 1] = infinity;
    for (var i = 1; i <= firstLength; i++) {
      current[0] = i;
      final lower = math.max(1, i - limit);
      final upper = math.min(secondLength, i + limit);
      if (lower > 1) current[lower - 1] = infinity;
      current[upper + 1] = infinity;
      var minimum = infinity;
      for (var j = lower; j <= upper; j++) {
        current[j] = math.min(
          previous[j] + 1,
          math.min(
            current[j - 1] + 1,
            previous[j - 1] +
                (first[start + i - 1] == second[start + j - 1] ? 0 : 1),
          ),
        );
        minimum = math.min(minimum, current[j]);
      }
      if (minimum > limit) return false;
      final swap = previous;
      previous = current;
      current = swap;
    }
    return previous[secondLength] <= limit;
  }
}

class _MergeGroup {
  _MergeGroup(this.element, this.text, this.runes, this.meaning, this.index);
  final int index;
  final DanmakuElem element;
  final String text;
  final List<int> runes;
  final String meaning;
  int get bytes =>
      384 +
      estimateDanmakuElementBytes(element) +
      2 * (text.length + meaning.length) +
      8 * runes.length;
}

double mergedDanmakuFontScale(
  int count, {
  required bool enabled,
  required int threshold,
  required double logBase,
}) => !enabled || count <= threshold || count <= 1
    ? 1
    : (math.log(count) / math.log(logBase)).clamp(1.0, 2.0);
