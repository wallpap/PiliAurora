import 'dart:collection';

class LiveChatMessage<T> {
  const LiveChatMessage({required this.id, required this.content});

  // 房间内单调递增，不依赖服务端是否提供消息 ID。
  final int id;
  final T content;
}

/// 翻阅时冻结历史，只在恢复跟随时合并有界积压。
class LiveChatBuffer<T> {
  LiveChatBuffer({this.maxHistory = 500, this.maxPending = 500}) {
    if (maxHistory <= 0 || maxPending <= 0) {
      throw ArgumentError('消息容量必须大于零');
    }
  }

  final int maxHistory;
  final int maxPending;
  final _history = ListQueue<LiveChatMessage<T>>();
  final _pending = ListQueue<LiveChatMessage<T>>();
  int _nextId = 0;
  bool _paused = false;
  int _revision = 0;
  int _droppedPending = 0;
  bool _historyTruncated = false;
  List<LiveChatMessage<T>>? _historySnapshot;

  int get historyCount => _history.length;
  int get pendingCount => _pending.length;
  int get droppedPending => _droppedPending;
  bool get historyTruncated => _historyTruncated;
  int get revision => _revision;

  List<LiveChatMessage<T>> get history =>
      _historySnapshot ??= List.unmodifiable(_history);

  void pause() => _paused = true;

  void add(T content) {
    final message = LiveChatMessage(id: _nextId++, content: content);
    if (_paused) {
      if (_pending.length == maxPending) {
        _pending.removeFirst();
        _droppedPending++;
      }
      _pending.addLast(message);
    } else {
      _addHistory(message);
    }
  }

  void _addHistory(LiveChatMessage<T> message) {
    if (_history.length == maxHistory) {
      _history.removeFirst();
      _historyTruncated = true;
    }
    _history.addLast(message);
    _historySnapshot = null;
    _revision++;
  }

  void resume() {
    _paused = false;
    if (_droppedPending > 0) {
      _historyTruncated = true;
    }
    while (_pending.isNotEmpty) {
      _addHistory(_pending.removeFirst());
    }
    _droppedPending = 0;
  }

  void clear() {
    _history.clear();
    _pending.clear();
    _historySnapshot = null;
    _paused = false;
    _droppedPending = 0;
    _historyTruncated = false;
    _revision++;
  }
}
