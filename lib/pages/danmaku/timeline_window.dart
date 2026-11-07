import 'dart:collection';

/// 已编排结果；payload 由显示层持有，可包含轨迹或明确的略过决定。
class DanmakuWindowItem<T> {
  const DanmakuWindowItem({
    required this.identity,
    required this.sourceUs,
    required this.startUs,
    required this.endUs,
    required this.estimatedBytes,
    required this.payload,
  });

  final Object identity;
  final int sourceUs;
  final int startUs;
  final int endUs;
  final int estimatedBytes;
  final T payload;
}

/// 有界编排索引。准备与资源工作在帧求值之外，时间统一使用媒体微秒。
class DanmakuTimelineWindow<T> {
  DanmakuTimelineWindow({this.maxItems = 3072, this.maxBytes = 5 * 1024 * 1024})
    : assert(maxItems > 0),
      assert(maxBytes > 0);

  final int maxItems;
  final int maxBytes;
  final _items = <Object, DanmakuWindowItem<T>>{};
  final _starts = <DanmakuWindowItem<T>>[];
  final _active = <Object, DanmakuWindowItem<T>>{};
  final _activeEnds = SplayTreeMap<int, Set<Object>>();
  int _bytes = 0;
  int _generation = 0;
  int _validFromUs = 0;
  int _validUntilUs = 0;
  int? _positionUs;
  int _nextStart = 0;

  int get generation => _generation;
  int get validFromUs => _validFromUs;
  int get validUntilUs => _validUntilUs;
  int get length => _items.length;
  int get estimatedBytes => _bytes;
  DanmakuWindowItem<T>? itemFor(Object identity) => _items[identity];
  bool hasIdentity(Object identity) => _items.containsKey(identity);
  List<DanmakuWindowItem<T>> get preparedItems => List.unmodifiable(_starts);

  bool contains(int positionUs) =>
      _validFromUs <= positionUs && positionUs < _validUntilUs;

  /// 冷 seek 或轨迹重锚定开始新的局部域；旧准备任务不能写入新域。
  void reset(int fromUs) {
    if (fromUs < 0) throw ArgumentError.value(fromUs);
    _generation++;
    _validFromUs = _validUntilUs = fromUs;
    _items.clear();
    _starts.clear();
    _bytes = 0;
    _clearActive();
  }

  /// 整批获准后扩展完整前沿；lookaheadUntilUs 允许先编排前沿之后的优先项，
  /// 这些项不扩大 contains 的完整覆盖，来源时间保持原值。
  /// 失败时调用方缩小准备批次，旧结果保持有效。
  bool extend(
    Iterable<DanmakuWindowItem<T>> additions, {
    required int generation,
    required int preparedUntilUs,
    int? lookaheadUntilUs,
  }) {
    if (generation != _generation) return false;
    if (preparedUntilUs < _validUntilUs) {
      throw ArgumentError.value(preparedUntilUs);
    }
    if (lookaheadUntilUs != null && lookaheadUntilUs < preparedUntilUs) {
      throw ArgumentError.value(lookaheadUntilUs, 'lookaheadUntilUs');
    }
    final pending = <Object, DanmakuWindowItem<T>>{};
    var bytes = _bytes;
    for (final item in additions) {
      if (item.startUs < 0 ||
          item.endUs <= item.startUs ||
          item.estimatedBytes < 0 ||
          item.startUs > (lookaheadUntilUs ?? preparedUntilUs)) {
        throw ArgumentError('编排结果必须具有有效区间、预算并位于准备前沿内');
      }
      if (item.endUs <= _validFromUs ||
          _items.containsKey(item.identity) ||
          pending.containsKey(item.identity)) {
        continue;
      }
      pending[item.identity] = item;
      bytes += item.estimatedBytes;
      if (_items.length + pending.length > maxItems || bytes > maxBytes) {
        return false;
      }
    }
    _items.addAll(pending);
    _bytes = bytes;
    _validUntilUs = preparedUntilUs;
    if (pending.isNotEmpty) {
      // 仅排序新增项并归并；正常顺播直接追加，避免每小批重排整个窗口。
      final ordered = pending.values.indexed.toList()
        ..sort((a, b) {
          final time = a.$2.startUs.compareTo(b.$2.startUs);
          return time != 0 ? time : a.$1.compareTo(b.$1);
        });
      if (_starts.isEmpty || _starts.last.startUs <= ordered.first.$2.startUs) {
        _starts.addAll(ordered.map((e) => e.$2));
      } else {
        final merged = <DanmakuWindowItem<T>>[];
        var left = 0;
        var right = 0;
        while (left < _starts.length && right < ordered.length) {
          // 同时刻旧结果先于迟到数据。
          if (_starts[left].startUs <= ordered[right].$2.startUs) {
            merged.add(_starts[left++]);
          } else {
            merged.add(ordered[right++].$2);
          }
        }
        merged
          ..addAll(_starts.skip(left))
          ..addAll(ordered.skip(right).map((e) => e.$2));
        _starts
          ..clear()
          ..addAll(merged);
      }
      // 纯前瞻追加不改变当前位置之前的索引，继续消费入场／到期事件。
      if (_positionUs == null || ordered.first.$2.startUs <= _positionUs!) {
        _clearActive();
      }
    }
    return true;
  }

  /// 正向热帧仅消费新入场和到期事件；域内回跳恢复完整可见集合。
  /// allowUnprepared 用于顺播呈现尚未补齐前沿时的已知项，不扩大缓存回查域。
  List<DanmakuWindowItem<T>>? visibleAt(
    int positionUs, {
    bool allowUnprepared = false,
  }) {
    if (positionUs < _validFromUs ||
        (!allowUnprepared && !contains(positionUs))) {
      return null;
    }
    if (_positionUs == null || positionUs < _positionUs!) {
      _clearActive();
      var lower = 0;
      var upper = _starts.length;
      while (lower < upper) {
        final middle = (lower + upper) >> 1;
        if (_starts[middle].startUs <= positionUs) {
          lower = middle + 1;
        } else {
          upper = middle;
        }
      }
      _nextStart = lower;
      for (var index = 0; index < lower; index++) {
        final item = _starts[index];
        if (item.endUs > positionUs) _activate(item);
      }
    } else {
      while (_nextStart < _starts.length &&
          _starts[_nextStart].startUs <= positionUs) {
        final item = _starts[_nextStart++];
        if (item.endUs > positionUs) _activate(item);
      }
      while (_activeEnds.isNotEmpty && _activeEnds.firstKey()! <= positionUs) {
        for (final identity in _activeEnds.remove(_activeEnds.firstKey())!) {
          _active.remove(identity);
        }
      }
    }
    _positionUs = positionUs;
    return List.unmodifiable(_active.values);
  }

  /// 按实际结束时间裁剪，跨入后沿的长轨迹仍然保留。
  void trimBefore(int fromUs) {
    if (fromUs <= _validFromUs) return;
    if (fromUs > _validUntilUs) throw ArgumentError.value(fromUs);
    _validFromUs = fromUs;
    _items.removeWhere((_, item) {
      if (item.endUs > fromUs) return false;
      _bytes -= item.estimatedBytes;
      return true;
    });
    _starts.removeWhere((item) => !_items.containsKey(item.identity));
    _clearActive();
  }

  void _activate(DanmakuWindowItem<T> item) {
    _active[item.identity] = item;
    (_activeEnds[item.endUs] ??= {}).add(item.identity);
  }

  void _clearActive() {
    _active.clear();
    _activeEnds.clear();
    _positionUs = null;
    _nextStart = 0;
  }
}
