import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/element_size.dart';
import 'package:pili_aurora/pages/danmaku/priority.dart';

DanmakuElem _dm(
  int id, {
  int weight = 3,
  int progress = 0,
  bool self = false,
}) => DanmakuElem(
  content: '$id',
  progress: progress,
  weight: weight,
  isSelf: self,
);

void main() {
  test('promoted earlier representatives win equal-weight ties', () {
    for (final sameBucket in [true, false]) {
      final retained =
          DanmakuPriorityRetention(
              maxElements: sameBucket ? 10 : 1,
              maxPerBucket: 1,
              maxBytes: 10000,
            )
            ..add(0, _dm(0))
            ..add(1, _dm(1, weight: 9, progress: sameBucket ? 0 : 100))
            ..promote(0, _dm(0, weight: 9));
      expect(retained.buckets.values.expand((e) => e).single.content, '0');
    }
  });

  test('bounded selection matches stable priority sort on shuffled inputs', () {
    final random = Random(8);
    for (var trial = 0; trial < 50; trial++) {
      final input = List.generate(
        500,
        (i) => _dm(i, weight: random.nextInt(12), self: i % 81 == 0),
      );
      final expected = input.indexed.toList()
        ..sort((a, b) {
          final priority = compareDanmakuPriority(a.$2, b.$2);
          return priority != 0 ? priority : a.$1.compareTo(b.$1);
        });
      final indices = expected.take(23).map((e) => e.$1).toList()..sort();
      expect(selectDanmakuPriority(input, 23, compareDanmakuPriority), [
        for (final i in indices) input[i],
      ]);
    }
  });

  test('retention replaces low priority across bucket and global limits', () {
    final retained = DanmakuPriorityRetention(
      maxElements: 3,
      maxPerBucket: 2,
      maxBytes: 10000,
    );
    final low = _dm(0);
    final high = _dm(2, weight: 10);
    final self = _dm(4, self: true);
    retained
      ..add(0, low)
      ..add(1, _dm(1))
      ..add(2, high)
      ..add(3, _dm(3, progress: 100, weight: 9))
      ..add(4, self);
    final items = retained.buckets.values.expand((e) => e).toList();
    expect(items, containsAll([high, self]));
    expect(items, isNot(contains(low)));
    expect(items.length, 3);
    expect(retained.buckets[0]!.length, 2);
    final bytes =
        items.fold<int>(
          0,
          (sum, e) => sum + estimateDanmakuElementBytes(e) + 64,
        ) +
        retained.buckets.length * 128;
    expect(retained.estimatedBytes, bytes);
  });

  test('byte pressure rejects an oversized candidate atomically', () {
    final retained = DanmakuPriorityRetention(
      maxElements: 10,
      maxPerBucket: 10,
      maxBytes: 1400,
      baseBytes: 128,
    );
    final before = retained.estimatedBytes;
    retained
      ..add(0, _dm(0))
      ..add(1, _dm(1));
    final after = retained.estimatedBytes;
    retained.add(2, DanmakuElem(content: 'x' * 2000, weight: 11));
    expect(before, 128);
    expect(retained.estimatedBytes, after);
    expect(retained.buckets[0]!.length, 1);
    retained.add(3, _dm(3, weight: 9));
    expect(retained.buckets[0]!.single.content, '3');
    expect(retained.estimatedBytes, lessThanOrEqualTo(1400));
  });

  test(
    'a later merged high weight representative can return after eviction',
    () {
      final retained =
          DanmakuPriorityRetention(
              maxElements: 1,
              maxPerBucket: 1,
              maxBytes: 10000,
            )
            ..add(0, _dm(0))
            ..add(1, _dm(1, weight: 9))
            ..promote(0, _dm(0, weight: 11)..count = 8);
      expect(retained.buckets[0]!.single.content, '0');
      expect(retained.buckets[0]!.single.count, 8);
      retained.updateCount(0, 9);
      expect(retained.buckets[0]!.single.count, 9);
      retained.add(2, _dm(2, weight: 12));
      expect(retained.buckets[0]!.single.content, '2');
    },
  );
}
