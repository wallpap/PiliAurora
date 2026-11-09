import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/app_exit.dart';

void main() {
  test('退出合并并发请求，等待清理与结束操作，失败不跳过独立步骤', () async {
    final cleaning = Completer<void>();
    final terminating = Completer<void>();
    final cause = StateError('synthetic storage failure');
    final stack = StackTrace.fromString('#0 storage.compact');
    final calls = <String>[];
    final failures = <(String, Object, StackTrace)>[];
    final exit = AppExit(
      cleanup: [
        (
          'progress',
          () {
            calls.add('progress');
            return cleaning.future;
          },
        ),
        ('compact', () => Error.throwWithStackTrace(cause, stack)),
        ('storage', () => calls.add('storage')),
      ],
      terminate: () {
        calls.add('terminate');
        return terminating.future;
      },
      onFailure: (phase, error, trace) => failures.add((phase, error, trace)),
    );
    var completed = false;
    final first = exit.close();
    final observing = first.then((_) => completed = true);
    expect(exit.close(), same(first));
    expect(exit.isClosing, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['progress']);
    cleaning.complete();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['progress', 'storage', 'terminate']);
    expect(completed, isFalse);
    expect(failures.single.$1, 'compact');
    expect(failures.single.$2, same(cause));
    expect(failures.single.$3.toString(), stack.toString());
    terminating.complete();
    await observing;
    expect(completed, isTrue);
    expect(exit.isClosing, isFalse);
  });

  test('退出失败保留原始原因与堆栈，诊断失败不覆盖结果且允许重试', () async {
    final cause = StateError('synthetic termination failure');
    final stack = StackTrace.fromString('#0 process.terminate');
    var attempts = 0;
    final exit = AppExit(
      terminate: () {
        if (attempts++ == 0) Error.throwWithStackTrace(cause, stack);
      },
      onFailure: (_, _, _) => throw StateError('synthetic logger failure'),
    );
    try {
      await exit.close();
      fail('termination should fail');
    } catch (error, trace) {
      expect(error, same(cause));
      expect(trace.toString(), stack.toString());
    }
    expect(exit.isClosing, isFalse);
    await exit.close();
    expect(attempts, 2);
  });

  testWidgets('诊断刷新超时后继续退出，迟到失败不会成为未处理异常', (tester) async {
    final flushing = Completer<void>();
    final failures = <(String, Object)>[];
    var terminated = false;
    final exit = AppExit(
      flushDiagnostics: () => flushing.future,
      terminate: () => terminated = true,
      onFailure: (phase, error, _) => failures.add((phase, error)),
    );
    final closing = exit.close();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(terminated, isFalse);
    await tester.pump(const Duration(seconds: 1));
    await closing;
    expect(terminated, isTrue);
    expect(failures.single.$1, 'diagnostics');
    expect(failures.single.$2, isA<TimeoutException>());
    flushing.completeError(StateError('synthetic late failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test('清理失败的诊断也失败时，仍尝试其余清理和退出', () async {
    final calls = <String>[];
    final exit = AppExit(
      cleanup: [
        ('progress', () => throw StateError('synthetic progress failure')),
        ('storage', () => calls.add('storage')),
      ],
      flushDiagnostics: () => Future<void>.error(StateError('synthetic flush')),
      terminate: () => calls.add('terminate'),
      onFailure: (_, _, _) => throw StateError('synthetic logger failure'),
    );
    await exit.close();
    expect(calls, ['storage', 'terminate']);
  });
}
