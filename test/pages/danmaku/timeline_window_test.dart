import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/timeline_window.dart';

DanmakuWindowItem<String> _item(
  String id,
  int start,
  int end, {
  int bytes = 10,
}) => DanmakuWindowItem(
  identity: id,
  sourceUs: start,
  startUs: start,
  endUs: end,
  estimatedBytes: bytes,
  payload: id,
);

void main() {
  test(
    'interleaved future additions and late entries keep active expiry exact',
    () {
      final window = DanmakuTimelineWindow<String>();
      void add(List<DanmakuWindowItem<String>> items) => window.extend(
        items,
        generation: window.generation,
        preparedUntilUs: 1000,
      );
      add([_item('active', 0, 100), _item('later', 300, 400)]);
      expect(window.visibleAt(50)!.single.identity, 'active');
      add([_item('future', 200, 350)]);
      expect(window.visibleAt(100), isEmpty);
      expect(window.visibleAt(250)!.single.identity, 'future');
      add([_item('late', 150, 500)]);
      expect(window.visibleAt(300)!.map((e) => e.identity), [
        'late',
        'future',
        'later',
      ]);
      expect(window.visibleAt(400)!.single.identity, 'late');
      expect(window.visibleAt(500), isEmpty);
    },
  );

  test(
    'priority lookahead does not grant coverage past an incomplete frontier',
    () {
      final window = DanmakuTimelineWindow<String>();
      window.extend(
        [_item('future', 90, 200)],
        generation: window.generation,
        preparedUntilUs: 0,
        lookaheadUntilUs: 100,
      );
      expect(window.contains(90), isFalse);
      expect(window.visibleAt(90), isNull);
      expect(
        window.visibleAt(90, allowUnprepared: true)!.single.identity,
        'future',
      );
      expect(
        () => window.extend(
          const [],
          generation: window.generation,
          preparedUntilUs: 100,
          lookaheadUntilUs: 99,
        ),
        throwsArgumentError,
      );
      window.extend(
        [_item('earlier', 0, 200)],
        generation: window.generation,
        preparedUntilUs: 100,
      );
      expect(window.visibleAt(95)!.map((e) => e.identity), [
        'earlier',
        'future',
      ]);
    },
  );

  test('partial boundary results render without granting complete cached query coverage', () {
    final window = DanmakuTimelineWindow<String>();
    expect(
      window.extend(
        [_item('first', 0, 100)],
        generation: window.generation,
        preparedUntilUs: 0,
      ),
      isTrue,
    );
    expect(window.contains(0), isFalse);
    expect(window.visibleAt(0), isNull);
    expect(window.visibleAt(0, allowUnprepared: true)!.single.payload, 'first');
    window.extend(
      [_item('second', 0, 100)],
      generation: window.generation,
      preparedUntilUs: 100,
    );
    expect(window.visibleAt(50)!.map((e) => e.payload), ['first', 'second']);
  });

  test(
    'half-open intervals survive skipped frame buckets and cached backseek',
    () {
      final window = DanmakuTimelineWindow<String>();
      window.extend(
        [
          _item('long', 0, 1000),
          _item('expired', 100, 150),
          _item('current', 200, 400),
          _item('future', 500, 700),
        ],
        generation: window.generation,
        preparedUntilUs: 1000,
      );
      expect(window.visibleAt(0)!.map((e) => e.payload), ['long']);
      expect(window.visibleAt(350)!.map((e) => e.payload), ['long', 'current']);
      expect(window.visibleAt(400)!.map((e) => e.payload), ['long']);
      expect(window.visibleAt(600)!.map((e) => e.payload), ['long', 'future']);
      expect(window.visibleAt(125)!.map((e) => e.payload), ['long', 'expired']);
      expect(window.visibleAt(1000), isNull);
    },
  );

  test(
    'late additions keep established identities and stable equal-time order',
    () {
      final window = DanmakuTimelineWindow<String>();
      window.extend(
        [_item('a', 100, 500)],
        generation: window.generation,
        preparedUntilUs: 600,
      );
      window.visibleAt(300);
      window.extend(
        [_item('a', 100, 200), _item('b', 100, 500)],
        generation: window.generation,
        preparedUntilUs: 700,
      );
      expect(window.visibleAt(300)!.map((e) => e.payload), ['a', 'b']);
      expect(window.length, 2);
    },
  );

  test(
    'capacity rejects the entire preparation batch without moving the frontier',
    () {
      final window = DanmakuTimelineWindow<String>(maxItems: 2, maxBytes: 15);
      expect(
        window.extend(
          [_item('a', 0, 100), _item('b', 10, 100)],
          generation: window.generation,
          preparedUntilUs: 100,
        ),
        isFalse,
      );
      expect(window.length, 0);
      expect(window.estimatedBytes, 0);
      expect(window.validUntilUs, 0);
      expect(
        window.extend(
          [_item('a', 0, 100)],
          generation: window.generation,
          preparedUntilUs: 100,
        ),
        isTrue,
      );
      expect(
        window.extend(
          [_item('b', 10, 100, bytes: 1), _item('c', 20, 100, bytes: 1)],
          generation: window.generation,
          preparedUntilUs: 200,
        ),
        isFalse,
      );
      expect(window.validUntilUs, 100);
      expect(window.length, 1);
    },
  );

  test('reanchoring cuts old query domain and rejects stale preparation', () {
    final window = DanmakuTimelineWindow<String>();
    final generation = window.generation;
    window
      ..extend(
        [_item('old', 0, 1000)],
        generation: generation,
        preparedUntilUs: 1000,
      )
      ..reset(800);
    expect(
      window.extend(
        [_item('stale', 900, 1100)],
        generation: generation,
        preparedUntilUs: 1200,
      ),
      isFalse,
    );
    window.extend(
      [_item('reanchored', 800, 1400)],
      generation: window.generation,
      preparedUntilUs: 1200,
    );
    expect(window.visibleAt(300), isNull);
    expect(window.visibleAt(800)!.single.payload, 'reanchored');
    expect(window.estimatedBytes, 10);
  });

  test('trimming keeps long trajectories that cross the history edge', () {
    final window = DanmakuTimelineWindow<String>();
    window.extend(
      [_item('long', 0, 1000), _item('ended', 100, 300)],
      generation: window.generation,
      preparedUntilUs: 1100,
    );
    window.trimBefore(500);
    expect(window.length, 1);
    expect(window.estimatedBytes, 10);
    expect(window.visibleAt(499), isNull);
    expect(window.visibleAt(500)!.single.payload, 'long');
    window.trimBefore(1000);
    expect(window.length, 0);
    expect(window.estimatedBytes, 0);
  });

  test(
    'incremental and random seek queries agree with interval visibility',
    () {
      final random = Random(17);
      final items = List.generate(100, (index) {
        final start = random.nextInt(500);
        return _item('$index', start, start + 1 + random.nextInt(300));
      });
      final window = DanmakuTimelineWindow<String>();
      window.extend(
        items,
        generation: window.generation,
        preparedUntilUs: 1000,
      );
      final order = {
        for (var i = 0; i < items.length; i++) items[i].identity: i,
      };
      final sorted = items.toList()
        ..sort((a, b) {
          final time = a.startUs.compareTo(b.startUs);
          return time == 0
              ? order[a.identity]!.compareTo(order[b.identity]!)
              : time;
        });
      for (final position in [
        for (var i = 0; i < 1000; i += 13) i,
        for (var i = 0; i < 100; i++) random.nextInt(1000),
      ]) {
        expect(
          window.visibleAt(position)!.map((e) => e.identity),
          sorted
              .where((e) => e.startUs <= position && position < e.endUs)
              .map((e) => e.identity),
        );
      }
    },
  );
}
