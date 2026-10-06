import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/utils/playback_load_queue.dart';

void main() {
  test('同一事件循环连续 run 只执行最后一个任务', () async {
    final PlaybackLoadQueue queue = PlaybackLoadQueue();
    final List<String> events = <String>[];

    expect(queue.isLoading, isFalse);
    final Future<void> first = queue.run((_) {
      events.add('first');
      return Future<void>.value();
    });
    expect(queue.isLoading, isTrue);
    final Future<void> second = queue.run((_) {
      events.add('second');
      return Future<void>.value();
    });
    final Future<void> latest = queue.run((_) {
      events.add('latest');
      return Future<void>.value();
    });

    // 代次和加载态同步更新，但尚未开始的首任务也允许被替代。
    expect(events, isEmpty);
    expect(queue.isLoading, isTrue);
    await Future.wait<void>(<Future<void>>[first, second, latest]);
    expect(events, <String>['latest']);
    expect(queue.isLoading, isFalse);
  });

  test('任务互斥执行，不会并行进入 operation', () async {
    final PlaybackLoadQueue queue = PlaybackLoadQueue();
    final List<String> events = <String>[];
    final Completer<void> firstStarted = Completer<void>();
    final Completer<void> secondStarted = Completer<void>();
    final Completer<void> first = Completer<void>();
    final Completer<void> second = Completer<void>();

    final Future<void> f1 = queue.run((_) async {
      events.add('enter1');
      firstStarted.complete();
      await first.future;
      events.add('exit1');
    });
    await firstStarted.future;
    final Future<void> f2 = queue.run((_) async {
      events.add('enter2');
      secondStarted.complete();
      await second.future;
      events.add('exit2');
    });

    expect(events, <String>['enter1']);
    expect(secondStarted.isCompleted, isFalse);
    expect(queue.isLoading, isTrue);

    first.complete();
    await f1;
    await secondStarted.future;
    expect(events, <String>['enter1', 'exit1', 'enter2']);
    expect(queue.isLoading, isTrue);

    second.complete();
    await f2;
    expect(events, <String>['enter1', 'exit1', 'enter2', 'exit2']);
    expect(queue.isLoading, isFalse);
  });

  test('operation 内同步 run 不会并行执行嵌套任务', () async {
    final PlaybackLoadQueue queue = PlaybackLoadQueue();
    final List<String> events = <String>[];
    final Completer<void> outerStarted = Completer<void>();
    final Completer<void> nestedStarted = Completer<void>();
    final Completer<void> outerGate = Completer<void>();
    final Completer<void> nestedGate = Completer<void>();
    int active = 0;
    int maxActive = 0;
    late Future<void> nested;

    final Future<void> outer = queue.run((_) async {
      active++;
      maxActive = active;
      events.add('outer-enter');
      // 只同步入队，不在外层 await 嵌套任务，否则串行依赖会自锁。
      nested = queue.run((_) async {
        active++;
        if (active > maxActive) maxActive = active;
        events.add('nested-enter');
        nestedStarted.complete();
        await nestedGate.future;
        events.add('nested-exit');
        active--;
      });
      outerStarted.complete();
      await outerGate.future;
      events.add('outer-exit');
      active--;
    });

    await outerStarted.future;
    outerGate.complete();
    await outer;
    await nestedStarted.future;
    nestedGate.complete();
    await nested;

    expect(maxActive, 1);
    expect(active, 0);
    expect(events, <String>[
      'outer-enter',
      'outer-exit',
      'nested-enter',
      'nested-exit',
    ]);
    expect(queue.isLoading, isFalse);
  });

  test('排队中的旧任务被跳过，仅最新任务执行', () async {
    final PlaybackLoadQueue queue = PlaybackLoadQueue();
    final List<String> events = <String>[];
    final Completer<void> started = Completer<void>();
    final Completer<void> blocker = Completer<void>();

    final Future<void> blockerFuture = queue.run((_) async {
      events.add('blocker');
      started.complete();
      await blocker.future;
    });
    await started.future;
    final Future<void> stale = queue.run((_) {
      events.add('stale');
      return Future<void>.value();
    });
    final Future<void> latest = queue.run((_) {
      events.add('latest');
      return Future<void>.value();
    });

    blocker.complete();
    await Future.wait<void>(<Future<void>>[blockerFuture, stale, latest]);
    expect(events, <String>['blocker', 'latest']);
    expect(queue.isLoading, isFalse);
  });

  test('运行中任务在 await 之后通过 isCurrent 发现失效', () async {
    final PlaybackLoadQueue queue = PlaybackLoadQueue();
    final Completer<void> started = Completer<void>();
    final Completer<void> gate = Completer<void>();
    final List<bool> observed = <bool>[];
    final List<String> events = <String>[];
    late bool Function() runningIsCurrent;

    final Future<void> running = queue.run((bool Function() isCurrent) async {
      runningIsCurrent = isCurrent;
      events.add('running-start');
      started.complete();
      await gate.future;
      observed.add(isCurrent());
      if (isCurrent()) {
        events.add('running-commit');
      }
    });

    await started.future;
    expect(runningIsCurrent(), isTrue);
    final Future<void> newer = queue.run((_) {
      events.add('newer');
      return Future<void>.value();
    });
    expect(runningIsCurrent(), isFalse);
    gate.complete();
    await running;
    await newer;

    expect(observed, <bool>[false]);
    expect(events, <String>['running-start', 'newer']);
    expect(queue.isLoading, isFalse);
  });

  test('任务异常只回传自身 Future，后续任务仍可执行', () async {
    final PlaybackLoadQueue queue = PlaybackLoadQueue();
    final List<String> events = <String>[];
    final StateError error = StateError('boom');

    final Future<void> failing = queue.run((_) {
      events.add('fail');
      throw error;
    });
    await expectLater(failing, throwsA(same(error)));
    expect(queue.isLoading, isFalse);

    final Future<void> next = queue.run((_) {
      events.add('next');
      return Future<void>.value();
    });
    await next;

    expect(events, <String>['fail', 'next']);
    expect(queue.isLoading, isFalse);
  });

  test('异步异常不泄漏到 zone，旧任务失败不影响排队任务和加载态', () async {
    final List<Object> uncaught = <Object>[];
    final StateError error = StateError('async boom');
    final StackTrace stackTrace = StackTrace.current;
    Object? receivedError;
    StackTrace? receivedStackTrace;
    bool? loadingDuringNext;
    late PlaybackLoadQueue queue;

    // 队列和调用方同处子 zone，显式捕获内部链路产生的未处理异常。
    await runZonedGuarded<Future<void>>(() async {
      queue = PlaybackLoadQueue();
      final Completer<void> started = Completer<void>();
      final Completer<void> gate = Completer<void>();
      final Future<void> failing = queue.run((_) async {
        started.complete();
        await gate.future;
        Error.throwWithStackTrace(error, stackTrace);
      });
      final Future<void> handled = failing.then<void>(
        (_) {},
        onError: (Object caught, StackTrace trace) {
          receivedError = caught;
          receivedStackTrace = trace;
        },
      );
      await started.future;
      final Future<void> next = queue.run((_) {
        loadingDuringNext = queue.isLoading;
        return Future<void>.value();
      });
      gate.complete();
      await handled;
      await next;
    }, (Object error, StackTrace _) => uncaught.add(error))!;

    expect(receivedError, same(error));
    expect(receivedStackTrace.toString(), stackTrace.toString());
    expect(loadingDuringNext, isTrue);
    expect(queue.isLoading, isFalse);
    expect(uncaught, isEmpty);
  });

  test('dispose 在首任务开始前使全部排队任务失效', () async {
    final PlaybackLoadQueue queue = PlaybackLoadQueue();
    final List<String> events = <String>[];
    final Future<void> first = queue.run((_) {
      events.add('first');
      return Future<void>.value();
    });
    final Future<void> second = queue.run((_) {
      events.add('second');
      return Future<void>.value();
    });

    queue.dispose();
    expect(queue.isLoading, isFalse);
    await Future.wait<void>(<Future<void>>[first, second]);
    expect(events, isEmpty);
    expect(queue.isLoading, isFalse);
  });

  test('dispose 使排队中的任务失效并阻止新任务执行', () async {
    final PlaybackLoadQueue queue = PlaybackLoadQueue();
    final List<String> events = <String>[];
    final Completer<void> started = Completer<void>();
    final Completer<void> blocker = Completer<void>();

    final Future<void> blockerFuture = queue.run((_) async {
      events.add('blocker');
      started.complete();
      await blocker.future;
    });
    await started.future;
    final Future<void> queued = queue.run((_) {
      events.add('queued');
      return Future<void>.value();
    });

    queue.dispose();
    expect(queue.isLoading, isFalse);
    blocker.complete();
    await Future.wait<void>(<Future<void>>[blockerFuture, queued]);
    expect(events, <String>['blocker']);
    expect(queue.isLoading, isFalse);

    final List<String> after = <String>[];
    final Future<void> ignored = queue.run((_) {
      after.add('after-dispose');
      return Future<void>.value();
    });
    expect(queue.isLoading, isFalse);
    await ignored;
    expect(after, isEmpty);
    expect(queue.isLoading, isFalse);
  });

  test('dispose 使运行中任务失效，isCurrent 返回 false', () async {
    final PlaybackLoadQueue queue = PlaybackLoadQueue();
    final Completer<void> started = Completer<void>();
    final Completer<void> gate = Completer<void>();
    final List<bool> observed = <bool>[];
    late bool Function() runningIsCurrent;

    final Future<void> running = queue.run((bool Function() isCurrent) async {
      runningIsCurrent = isCurrent;
      started.complete();
      await gate.future;
      observed.add(isCurrent());
    });

    await started.future;
    expect(queue.isLoading, isTrue);
    expect(runningIsCurrent(), isTrue);
    queue.dispose();
    expect(queue.isLoading, isFalse);
    expect(runningIsCurrent(), isFalse);

    gate.complete();
    await running;
    expect(observed, <bool>[false]);
    expect(queue.isLoading, isFalse);
  });

  test('旧任务收尾不清掉最新任务的加载态', () async {
    final PlaybackLoadQueue queue = PlaybackLoadQueue();
    final Completer<void> firstStarted = Completer<void>();
    final Completer<void> secondStarted = Completer<void>();
    final Completer<void> first = Completer<void>();
    final Completer<void> second = Completer<void>();
    final List<bool> loadingDuringSecond = <bool>[];

    final Future<void> f1 = queue.run((_) async {
      firstStarted.complete();
      await first.future;
    });
    await firstStarted.future;
    final Future<void> f2 = queue.run((_) async {
      // 旧任务此时才结束，不得把加载态提前清掉。
      loadingDuringSecond.add(queue.isLoading);
      secondStarted.complete();
      await second.future;
    });

    first.complete();
    await f1;
    expect(queue.isLoading, isTrue);
    await secondStarted.future;
    expect(loadingDuringSecond, <bool>[true]);
    expect(queue.isLoading, isTrue);

    second.complete();
    await f2;
    expect(queue.isLoading, isFalse);
  });
}
