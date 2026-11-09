import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/utils/playback_load_queue.dart';

void main() {
  test('时限模型：操作返回时已过 deadline，计时器尚未交付也必须超时', () async {
    var now = Duration.zero;
    final scheduler = PlaybackOperationScheduler(now: () => now);
    addTearDown(scheduler.dispose);
    final result = await scheduler.submit<int>(
      slot: PlaybackOperationSlot.seek,
      deadline: const Duration(seconds: 1),
      operation: (_) async {
        // 连续微任务或同步原生工作可以越过时限，Timer 还未得到执行机会。
        now = const Duration(seconds: 1);
        return 1;
      },
    );
    expect(result.outcome, PlaybackOperationOutcome.timedOut);
    await scheduler.drained;
    expect(scheduler.isRunning, isFalse);
  });

  test('越过 deadline 后抛错按超时结算，准时抛错仍为失败', () async {
    for (final late in [false, true]) {
      var now = Duration.zero;
      final scheduler = PlaybackOperationScheduler(now: () => now);
      var cancelled = 0;
      final result = await scheduler.submit<int>(
        slot: PlaybackOperationSlot.seek,
        deadline: const Duration(seconds: 1),
        cancel: () => cancelled++,
        operation: (_) {
          if (late) now = const Duration(seconds: 1);
          return Future<int>.error(StateError('failure'));
        },
      );
      expect(
        result.outcome,
        late
            ? PlaybackOperationOutcome.timedOut
            : PlaybackOperationOutcome.failed,
      );
      expect(cancelled, late ? 1 : 0);
      await scheduler.drained;
      scheduler.dispose();
    }
  });

  test('已被取代的操作越过 deadline 返回仍保持 superseded', () async {
    var now = Duration.zero;
    final scheduler = PlaybackOperationScheduler(now: () => now);
    final gate = Completer<void>();
    final first = scheduler.submit<int>(
      slot: PlaybackOperationSlot.seek,
      deadline: const Duration(seconds: 1),
      operation: (_) async {
        await gate.future;
        throw StateError('late');
      },
    );
    final next = scheduler.submit<int>(
      slot: PlaybackOperationSlot.seek,
      deadline: const Duration(seconds: 2),
      operation: (_) async => 2,
    );
    now = const Duration(seconds: 1);
    gate.complete();
    expect((await first).outcome, PlaybackOperationOutcome.superseded);
    expect((await next).outcome, PlaybackOperationOutcome.completed);
    await scheduler.drained;
    scheduler.dispose();
  });

  test('替换排队任务保留结果泛型、通知取消并让最新任务继续执行', () async {
    final clock = Stopwatch()..start();
    final scheduler = PlaybackOperationScheduler(now: () => clock.elapsed);
    final gate = Completer<int>();
    final events = <String>[];
    var pendingCancelled = 0;
    final deadline = clock.elapsed + const Duration(seconds: 5);
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete(1);
      scheduler.dispose();
      await scheduler.drained;
    });

    final active = scheduler.submit<int>(
      slot: PlaybackOperationSlot.load,
      deadline: deadline,
      operation: (_) {
        events.add('active');
        return gate.future;
      },
    );
    final pending = scheduler.submit<String>(
      slot: PlaybackOperationSlot.load,
      deadline: deadline,
      cancel: () => pendingCancelled++,
      operation: (_) async {
        events.add('pending');
        return 'old';
      },
    );
    final latest = scheduler.submit<bool>(
      slot: PlaybackOperationSlot.load,
      deadline: deadline,
      operation: (_) async {
        events.add('latest');
        return true;
      },
    );

    expect((await active).outcome, PlaybackOperationOutcome.superseded);
    expect((await pending).outcome, PlaybackOperationOutcome.superseded);
    expect(pendingCancelled, 1);
    expect(events, ['active']);
    expect(scheduler.isRunning, isTrue);

    gate.complete(1);
    final result = await latest;
    expect(result.outcome, PlaybackOperationOutcome.completed);
    expect(result.value, isTrue);
    await scheduler.drained;
    expect(events, ['active', 'latest']);
    expect(scheduler.isRunning, isFalse);
  });
}
