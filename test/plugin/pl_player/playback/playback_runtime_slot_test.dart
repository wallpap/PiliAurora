import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_runtime_slot.dart';

void main() {
  test('诊断资源队列不占用主播放队列', () async {
    final clock = Stopwatch()..start();
    final primary = await PlaybackRuntimeSlot.shared.acquire(
      deadline: const Duration(seconds: 2),
      now: () => clock.elapsed,
    );
    final diagnostic = await PlaybackRuntimeSlot.isolated().acquire(
      deadline: const Duration(seconds: 2),
      now: () => clock.elapsed,
    );
    expect(primary, isNotNull);
    expect(diagnostic, isNotNull);
    diagnostic!.release();
    primary!.release();
  });

  test('初始化占位与released屏障共同阻止重复分配', () async {
    final slot = PlaybackRuntimeSlot.shared;
    final now = Stopwatch()..start();
    Duration clock() => now.elapsed;
    final first = await slot.acquire(
      deadline: clock() + const Duration(seconds: 2),
      now: clock,
    );
    expect(first, isNotNull);

    final secondFuture = slot.acquire(
      deadline: clock() + const Duration(seconds: 2),
      now: clock,
    );
    var secondSettled = false;
    unawaited(secondFuture.then((_) => secondSettled = true));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(secondSettled, isFalse);

    final released = Completer<void>();
    first!.attachReleased(released.future);
    released.complete();
    final second = await secondFuture;
    expect(second, isNotNull);
    second!.release();
  });

  test('released失败时隔离slot，不把资源分配给新runtime', () async {
    final slot = PlaybackRuntimeSlot.shared;
    final now = Stopwatch()..start();
    Duration clock() => now.elapsed;
    final lease = await slot.acquire(
      deadline: clock() + const Duration(seconds: 2),
      now: clock,
    );
    expect(lease, isNotNull);

    final released = Completer<void>();
    lease!.attachReleased(released.future);
    released.completeError(StateError('native release unconfirmed'));
    await Future<void>.delayed(Duration.zero);

    final next = await slot.acquire(
      deadline: clock() + const Duration(seconds: 1),
      now: clock,
    );
    expect(next, isNull);
  });
}
