import 'package:pili_aurora/pages/live_room/chat_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rejects nonpositive capacities', () {
    expect(() => LiveChatBuffer<int>(maxHistory: 0), throwsArgumentError);
    expect(() => LiveChatBuffer<int>(maxPending: -1), throwsArgumentError);
  });

  test('following a busy room keeps only the latest 500 messages', () {
    final buffer = LiveChatBuffer<int>();
    for (var i = 0; i < 100000; i++) {
      buffer.add(i);
    }
    expect(buffer.historyCount, 500);
    expect(buffer.pendingCount, 0);
    expect(buffer.history.first.content, 99500);
    expect(buffer.history.last.content, 99999);
    expect(buffer.historyTruncated, isTrue);
  });

  test('reading history freezes entries while bounding unread backlog', () {
    final buffer = LiveChatBuffer<int>();
    for (var i = 0; i < 500; i++) {
      buffer.add(i);
    }
    final visible = buffer.history;
    final revision = buffer.revision;
    buffer.pause();
    for (var i = 500; i < 100500; i++) {
      buffer.add(i);
    }
    expect(buffer.history, orderedEquals(visible));
    expect(buffer.revision, revision);
    expect(buffer.historyCount + buffer.pendingCount, 1000);
    expect(buffer.pendingCount, 500);
    expect(buffer.droppedPending, 99500);
    buffer.resume();
    expect(buffer.history.first.content, 100000);
    expect(buffer.history.last.content, 100499);
    expect(buffer.pendingCount, 0);
    expect(buffer.droppedPending, 0);
    expect(buffer.historyTruncated, isTrue);
  });

  test('resuming merges retained unread entries in order with stable IDs', () {
    final buffer = LiveChatBuffer<String>(maxHistory: 4, maxPending: 2)
      ..add('旧消息一')
      ..add('旧消息二');
    final old = buffer.history;
    buffer
      ..pause()
      ..add('重复文本')
      ..add('重复文本');
    final revision = buffer.revision;
    buffer.resume();
    expect(buffer.history.map((message) => message.content), [
      '旧消息一',
      '旧消息二',
      '重复文本',
      '重复文本',
    ]);
    expect(buffer.history.take(2), orderedEquals(old));
    expect(buffer.history.map((message) => message.id), [0, 1, 2, 3]);
    expect(buffer.revision, greaterThan(revision));
    expect(buffer.historyTruncated, isFalse);
    buffer.resume();
    expect(buffer.historyCount, 4);
    expect(buffer.pendingCount, 0);
  });

  test('resume reports a gap even when history capacity was not reached', () {
    final buffer = LiveChatBuffer<int>(maxHistory: 10, maxPending: 2)
      ..add(0)
      ..pause()
      ..add(1)
      ..add(2)
      ..add(3)
      ..resume();
    expect(buffer.history.map((message) => message.content), [0, 2, 3]);
    expect(buffer.history.map((message) => message.id), [0, 2, 3]);
    expect(buffer.historyTruncated, isTrue);
    expect(buffer.droppedPending, 0);
  });

  test('same length replacements change revision and keep newest entries', () {
    final buffer = LiveChatBuffer<int>(maxHistory: 2)
      ..add(1)
      ..add(2);
    final revision = buffer.revision;
    final snapshot = buffer.history;
    buffer.add(3);
    expect(buffer.history.map((message) => message.content), [2, 3]);
    expect(buffer.revision, greaterThan(revision));
    expect(snapshot.map((message) => message.content), [1, 2]);
  });

  test('history reuses an immutable snapshot until it changes', () {
    final buffer = LiveChatBuffer<int>()..add(1);
    final first = buffer.history;
    expect(buffer.history, same(first));
    buffer.add(2);
    final second = buffer.history;
    expect(second, isNot(same(first)));
    expect(first.map((message) => message.content), [1]);
    expect(second.map((message) => message.content), [1, 2]);
    buffer.clear();
    expect(buffer.history, isNot(same(second)));
  });

  test(
    'repeated menu or background pauses do not reorder or duplicate messages',
    () {
      final buffer = LiveChatBuffer<int>(maxHistory: 4, maxPending: 2);
      for (var i = 0; i < 20; i++) {
        buffer
          ..pause()
          ..pause()
          ..add(i)
          ..resume()
          ..resume();
        expect(buffer.historyCount, lessThanOrEqualTo(4));
        expect(buffer.pendingCount, 0);
      }
      expect(buffer.history.map((message) => message.content), [
        16,
        17,
        18,
        19,
      ]);
      expect(buffer.history.map((message) => message.id), [16, 17, 18, 19]);
    },
  );

  test('clear releases both queues and does not reuse message IDs', () {
    final buffer = LiveChatBuffer<int>(maxHistory: 1, maxPending: 1)
      ..add(0)
      ..add(1)
      ..pause()
      ..add(2)
      ..add(3)
      ..clear();
    expect(buffer.historyCount, 0);
    expect(buffer.pendingCount, 0);
    expect(buffer.droppedPending, 0);
    expect(buffer.historyTruncated, isFalse);
    buffer.add(4);
    expect(buffer.history.single.id, 4);
    expect(buffer.history.single.content, 4);
  });
}
