import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/app/startup.dart';

void main() {
  test('启动成功只在完整装配结束后交付', () async {
    final progress = StartupProgress();
    final pending = Completer<void>();
    var completed = false;
    final result = progress.run(() => pending.future)
      ..then((_) => completed = true);
    await Future<void>.value();
    expect(completed, isFalse);
    pending.complete();
    expect(await result, isA<StartupSuccess>());
  });

  for (final asynchronous in [false, true]) {
    test('启动${asynchronous ? '异步' : '同步'}失败保留阶段、原始原因与堆栈', () async {
      final progress = StartupProgress();
      const cause = FileSystemException('private account body', '/private');
      final stack = StackTrace.fromString('original startup stack');
      final result = await progress.run(() {
        progress.phase = StartupPhase.storage;
        if (asynchronous) return Future<void>.error(cause, stack);
        Error.throwWithStackTrace(cause, stack);
      });
      expect(result, isA<StartupFailure>());
      final failure = result as StartupFailure;
      expect(failure, isA<Exception>());
      expect(failure.phase, StartupPhase.storage);
      expect(failure.cause, same(cause));
      expect(failure.stackTrace, same(stack));
      expect(failure.message, contains('本地配置或账号'));
      expect(failure.message, isNot(contains('private')));
      expect(failure.toString(), isNot(contains('private')));
    });
  }

  test('错误摘要包含阶段与系统码，脱敏路径和凭据且省略原始异常正文', () {
    final failure = StartupFailure(
      phase: StartupPhase.storage,
      cause: const FileSystemException(
        'unstructured private body',
        'C:\\Users\\PrivateUser\\account',
        OSError('secret body', 5),
      ),
      stackTrace: StackTrace.fromString(
        '#0 startup (C:\\Users\\PrivateUser\\app.dart:1)\n'
        '#1 load (https://example.test/data?token=private-value)\n',
      ),
    );
    final summary = failure.diagnosticSummary;
    expect(summary, contains('Stage: storage'));
    expect(summary, contains('Cause: FileSystemException'));
    expect(summary, contains('OS error: 5'));
    for (final secret in [
      'unstructured',
      'PrivateUser',
      'private-value',
      'secret body',
    ]) {
      expect(summary, isNot(contains(secret)));
    }
    expect(summary, contains('#0 startup'));
  });
}
