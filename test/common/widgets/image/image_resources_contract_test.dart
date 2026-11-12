import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/image_resources.dart';

Future<void> _flush() async {
  for (var turn = 0; turn < 12; turn++) {
    await Future<void>.value();
  }
}

void main() {
  test(
    'cancelled native work retains its permit until actual completion',
    () async {
      final resources = ImageResources(maximumConcurrentDecodes: 2);
      final gates = List.generate(3, (_) => Completer<int>());
      final started = <int>[];
      final released = <int>[];
      final jobs = List.generate(
        3,
        (index) => resources.schedule<int>(() {
          started.add(index);
          return gates[index].future;
        }, dispose: released.add),
      );
      await _flush();
      expect(started, [0, 1]);
      jobs[0].cancel();
      jobs[0].cancel();
      var drained = false;
      unawaited(jobs[0].drained.then((_) => drained = true));
      await _flush();
      expect(started, [0, 1]);
      expect(drained, isFalse);
      gates[0].complete(10);
      expect(await jobs[0].result, isNull);
      await jobs[0].drained;
      await _flush();
      expect(released, [10]);
      expect(started, [0, 1, 2]);
      gates[1].complete(11);
      gates[2].complete(12);
      expect(await jobs[1].result, 11);
      expect(await jobs[2].result, 12);
      expect(released, [10]);
      resources.dispose();
      await resources.drained;
    },
  );

  test(
    'queued cancellation never starts work or consumes another permit',
    () async {
      final resources = ImageResources(maximumConcurrentDecodes: 1);
      final gate = Completer<int>();
      final first = resources.schedule(() => gate.future, dispose: (_) {});
      var calls = 0;
      final queued = resources.schedule(() async => ++calls, dispose: (_) {});
      queued.cancel();
      expect(await queued.result, isNull);
      await queued.drained;
      gate.complete(1);
      expect(await first.result, 1);
      expect(calls, 0);
      resources.dispose();
      await resources.drained;
    },
  );

  test('long preprocessing leaves capacity for visible frames', () async {
    final resources = ImageResources(maximumConcurrentDecodes: 2);
    final heavyGate = Completer<int>();
    final otherGate = Completer<int>();
    final started = <String>[];
    final heavy = resources.schedule(
      () {
        started.add('heavy');
        return heavyGate.future;
      },
      dispose: (_) {},
      preprocessing: true,
    );
    final other = resources.schedule(
      () {
        started.add('other-heavy');
        return otherGate.future;
      },
      dispose: (_) {},
      preprocessing: true,
    );
    final visible = resources.schedule(() async {
      started.add('visible');
      return 3;
    }, dispose: (_) {});
    expect(await visible.result, 3);
    expect(started, ['heavy', 'visible']);
    heavyGate.complete(1);
    expect(await heavy.result, 1);
    await _flush();
    expect(started, ['heavy', 'visible', 'other-heavy']);
    otherGate.complete(2);
    expect(await other.result, 2);
    resources.dispose();
    await resources.drained;
  });

  test('failure preserves cause and stack and releases capacity', () async {
    final resources = ImageResources(maximumConcurrentDecodes: 1);
    final cause = StateError('synthetic decode failure');
    final stack = StackTrace.fromString('#0 synthetic.decoder');
    final failed = resources.schedule<int>(
      () => Future<int>.error(cause, stack),
      dispose: (_) {},
    );
    try {
      await failed.result;
      fail('decode should fail');
    } catch (error, trace) {
      expect(error, same(cause));
      expect(trace.toString(), contains('synthetic.decoder'));
    }
    final next = resources.schedule(() async => 42, dispose: (_) {});
    expect(await next.result, 42);
    await failed.drained;
    resources.dispose();
    await resources.drained;
  });

  test(
    'runtime shutdown revokes queued and native delivery before draining',
    () async {
      final resources = ImageResources(maximumConcurrentDecodes: 1);
      final gate = Completer<int>();
      final released = <int>[];
      final native = resources.schedule(
        () => gate.future,
        dispose: released.add,
      );
      var queuedCalls = 0;
      final queued = resources.schedule(
        () async => ++queuedCalls,
        dispose: released.add,
      );
      await _flush();
      resources.dispose();
      resources.dispose();
      expect(await queued.result, isNull);
      gate.complete(7);
      expect(await native.result, isNull);
      await resources.drained;
      expect(released, [7]);
      expect(queuedCalls, 0);
    },
  );

  test('visible work precedes prefetch without a busy owner monopolizing the queue', () async {
    final resources = ImageResources(maximumConcurrentDecodes: 1);
    final activeGate = Completer<int>();
    final active = resources.schedule(
      () => activeGate.future,
      dispose: (_) {},
      owner: 'article',
    );
    final order = <String>[];
    final article = resources.schedule(
      () async {
        order.add('article');
        return 1;
      },
      dispose: (_) {},
      owner: 'article',
    );
    final prefetch = resources.schedule(
      () async {
        order.add('prefetch');
        return 2;
      },
      dispose: (_) {},
      owner: 'gallery',
      priority: ImageWorkPriority.prefetch,
    );
    final gallery = resources.schedule(
      () async {
        order.add('gallery');
        return 3;
      },
      dispose: (_) {},
      owner: 'gallery',
    );
    activeGate.complete(0);
    expect(await active.result, 0);
    await Future.wait([article.result, prefetch.result, gallery.result]);
    expect(order, ['gallery', 'article', 'prefetch']);
    resources.dispose();
    await resources.drained;
  });
}
