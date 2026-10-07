import 'dart:async';

import 'package:pili_aurora/utils/rate_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

// 在 widget binding 核对计时器之前，先清理本用例注册的全局标签。
void _timedTest(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    try {
      await body(tester);
    } finally {
      ActionThrottle.cancel('first');
      ActionThrottle.cancel('second');
    }
  });
}

void main() {
  const interval = Duration(milliseconds: 100);

  _timedTest(
    'throttle runs the first action and drops duplicates until expiry',
    (
      tester,
    ) async {
      var calls = 0;
      expect(ActionThrottle.run('first', interval, () => calls++), isFalse);
      expect(calls, 1);
      expect(ActionThrottle.run('first', interval, () => calls++), isTrue);
      await tester.pump(const Duration(milliseconds: 99));
      expect(ActionThrottle.run('first', interval, () => calls++), isTrue);
      await tester.pump(const Duration(milliseconds: 1));
      expect(ActionThrottle.run('first', interval, () => calls++), isFalse);
      expect(calls, 2);
    },
  );

  _timedTest('throttle tags have independent cooldowns', (tester) async {
    var calls = 0;
    ActionThrottle.run('first', interval, () => calls++);
    ActionThrottle.run('second', interval, () => calls++);
    expect(calls, 2);
  });

  _timedTest('cancel clears one tag without releasing other tags', (
    tester,
  ) async {
    ActionThrottle.run('first', interval, () {});
    ActionThrottle.run('second', interval, () {});
    ActionThrottle.cancel('first');
    ActionThrottle.cancel('first');
    expect(ActionThrottle.run('first', interval, () {}), isFalse);
    expect(ActionThrottle.run('second', interval, () {}), isTrue);
  });

  _timedTest('throttle blocks synchronous reentry', (tester) async {
    var calls = 0;
    ActionThrottle.run('first', interval, () {
      calls++;
      expect(ActionThrottle.run('first', interval, () => calls++), isTrue);
    });
    expect(calls, 1);
  });

  _timedTest('throwing actions propagate and keep their cooldown', (
    tester,
  ) async {
    expect(
      () =>
          ActionThrottle.run('first', interval, () => throw StateError('test')),
      throwsStateError,
    );
    expect(ActionThrottle.run('first', interval, () {}), isTrue);
    await tester.pump(interval);
    expect(ActionThrottle.run('first', interval, () {}), isFalse);
  });

  _timedTest('cooldown does not wait for async action completion', (
    tester,
  ) async {
    final completion = Completer<void>();
    var calls = 0;
    ActionThrottle.run('first', interval, () async {
      calls++;
      await completion.future;
    });
    await tester.pump(interval);
    expect(ActionThrottle.run('first', interval, () => calls++), isFalse);
    completion.complete();
    await tester.pump(Duration.zero);
    expect(calls, 2);
  });

  _timedTest('zero duration still blocks duplicates in the same turn', (
    tester,
  ) async {
    ActionThrottle.run('first', Duration.zero, () {});
    expect(ActionThrottle.run('first', Duration.zero, () {}), isTrue);
    await tester.pump(Duration.zero);
    expect(ActionThrottle.run('first', Duration.zero, () {}), isFalse);
  });

  _timedTest('cancelled timer cannot release a replacement cooldown', (
    tester,
  ) async {
    ActionThrottle.run('first', interval, () {});
    await tester.pump(const Duration(milliseconds: 50));
    ActionThrottle.cancel('first');
    ActionThrottle.run('first', interval, () {});
    await tester.pump(const Duration(milliseconds: 50));
    expect(ActionThrottle.run('first', interval, () {}), isTrue);
    await tester.pump(const Duration(milliseconds: 50));
    expect(ActionThrottle.run('first', interval, () {}), isFalse);
  });

  _timedTest('debouncer emits only the last action after the quiet period', (
    tester,
  ) async {
    final debouncer = Debouncer(interval);
    final values = <int>[];
    debouncer.run(() => values.add(1));
    await tester.pump(const Duration(milliseconds: 50));
    debouncer.run(() => values.add(2));
    await tester.pump(const Duration(milliseconds: 99));
    expect(values, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(values, [2]);
  });

  _timedTest('debouncer cancellation is idempotent and permits reuse', (
    tester,
  ) async {
    final debouncer = Debouncer(interval);
    var calls = 0;
    debouncer
      ..run(() => calls++)
      ..cancel()
      ..cancel();
    await tester.pump(interval);
    expect(calls, 0);
    debouncer.run(() => calls++);
    await tester.pump(interval);
    expect(calls, 1);
  });

  _timedTest('debouncer can schedule another action inside its callback', (
    tester,
  ) async {
    final debouncer = Debouncer(interval);
    var calls = 0;
    debouncer.run(() {
      calls++;
      debouncer.run(() => calls++);
    });
    await tester.pump(interval);
    expect(calls, 1);
    await tester.pump(interval);
    expect(calls, 2);
  });

  _timedTest('zero delay debounce remains trailing', (tester) async {
    final debouncer = Debouncer(Duration.zero);
    final values = <int>[];
    debouncer
      ..run(() => values.add(1))
      ..run(() => values.add(2));
    expect(values, isEmpty);
    await tester.pump(Duration.zero);
    expect(values, [2]);
  });
}
