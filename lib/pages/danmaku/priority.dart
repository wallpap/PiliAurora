import 'dart:collection';

import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/element_size.dart';

/// 100 ms 的优先候选额度；真实素材与密集合成素材共同验证的折中值。
const danmakuCandidatesPerBucket = 12;

/// 负数表示先显示；自己发送的弹幕先于服务端权重，同权重保持来源次序。
int compareDanmakuPriority(DanmakuElem a, DanmakuElem b) {
  final self = (b.isSelf ? 1 : 0).compareTo(a.isSelf ? 1 : 0);
  return self != 0 ? self : b.weight.compareTo(a.weight);
}

/// 有界 top-k；返回来源次序，调用方继续遵守媒体时间顺序。
List<T> selectDanmakuPriority<T>(
  List<T> items,
  int limit,
  int Function(T, T) compare,
) {
  if (limit < 0) throw ArgumentError.value(limit, 'limit');
  if (limit == 0) return [];
  if (items.length <= limit) return items;
  final selected = SplayTreeSet<int>((a, b) {
    final priority = compare(items[b], items[a]);
    return priority != 0 ? priority : b.compareTo(a);
  });
  for (var i = 0; i < items.length; i++) {
    if (selected.length == limit) {
      if (compare(items[i], items[selected.first]) >= 0) continue;
      selected.remove(selected.first);
    }
    selected.add(i);
  }
  final indices = selected.toList()..sort();
  return [for (final i in indices) items[i]];
}

class _RetainedElement {
  _RetainedElement(this.index, this.element)
    : bytes = estimateDanmakuElementBytes(element) + 64;
  final int index;
  final DanmakuElem element;
  final int bytes;
  int get bucket => element.progress ~/ 100;
}

/// 文件和网络来源共用数量、字节与分桶额度；满额后替换低权重项。
/// 双有序索引使单项替换为 O(log n)，索引容量不随来源大小增长。
class DanmakuPriorityRetention {
  DanmakuPriorityRetention({
    required this.maxElements,
    required this.maxPerBucket,
    required this.maxBytes,
    this.baseBytes = 0,
  }) : assert(maxElements > 0 && maxPerBucket > 0 && maxBytes > 0),
       assert(baseBytes >= 0),
       estimatedBytes = baseBytes;

  final int maxElements;
  final int maxPerBucket;
  final int maxBytes;
  final int baseBytes;
  int estimatedBytes;
  final _byIndex = <int, _RetainedElement>{};
  final _buckets = <int, SplayTreeSet<_RetainedElement>>{};
  final _all = SplayTreeSet<_RetainedElement>(_compare);
  bool get isEmpty => _all.isEmpty;

  static int _compare(_RetainedElement a, _RetainedElement b) {
    final priority = compareDanmakuPriority(b.element, a.element);
    return priority != 0 ? priority : b.index.compareTo(a.index);
  }

  void add(int index, DanmakuElem element) {
    final entry = _RetainedElement(index, element);
    final bucket = _buckets[entry.bucket];
    final victims = <_RetainedElement>{};
    var bytes = estimatedBytes + entry.bytes + (bucket == null ? 128 : 0);
    if (bucket != null && bucket.length >= maxPerBucket) {
      final worst = bucket.first;
      if (_compare(entry, worst) <= 0) return;
      victims.add(worst);
      bytes -= worst.bytes;
    }
    for (final worst in _all) {
      if (_all.length - victims.length < maxElements && bytes <= maxBytes) {
        break;
      }
      if (victims.contains(worst)) continue;
      if (_compare(entry, worst) <= 0) return;
      victims.add(worst);
      bytes -= worst.bytes;
      // 空桶回收的索引字节在提交时核算；预检保守计费。
    }
    if (_all.length - victims.length >= maxElements || bytes > maxBytes) return;
    for (final victim in victims) {
      _remove(victim);
    }
    _buckets
        .putIfAbsent(entry.bucket, () {
          estimatedBytes += 128;
          return SplayTreeSet(_compare);
        })
        .add(entry);
    _all.add(entry);
    _byIndex[index] = entry;
    estimatedBytes += entry.bytes;
  }

  void promote(int index, DanmakuElem element) {
    final previous = _byIndex[index];
    if (previous != null) _remove(previous);
    add(index, element);
  }

  void updateCount(int index, int count) =>
      _byIndex[index]?.element.count = count;

  void _remove(_RetainedElement entry) {
    _all.remove(entry);
    _byIndex.remove(entry.index);
    final bucket = _buckets[entry.bucket]!..remove(entry);
    estimatedBytes -= entry.bytes;
    if (bucket.isEmpty) {
      _buckets.remove(entry.bucket);
      estimatedBytes -= 128;
    }
  }

  Map<int, List<DanmakuElem>> get buckets => {
    for (final entry in _buckets.entries)
      entry.key: [
        for (final item
            in (entry.value.toList()
              ..sort((a, b) => a.index.compareTo(b.index))))
          item.element,
      ],
  };
}
