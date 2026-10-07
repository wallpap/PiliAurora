import 'package:catcher_2/catcher_2.dart';
import 'package:catcher_2/utils/log_printer.dart';
import 'package:flutter_test/flutter_test.dart';

Report _report({Object? stack}) => Report(
  'fixture error',
  stack,
  DateTime(2026, 10, 7),
  const {'device': 'fixture'},
  const {'version': '1.0'},
  const {'build': 'fixture'},
  null,
);

void main() {
  ReportLog? previous;
  setUp(() {
    previous = Catcher2.logger;
    Catcher2.logger = null;
  });
  tearDown(() => Catcher2.logger = previous);

  test('console reports route through the host callback', () async {
    final events =
        <
          ({
            ReportLogLevel level,
            Object? message,
            Object? error,
            StackTrace? stack,
          })
        >[];
    Catcher2.logger = (level, message, {error, stackTrace}) {
      events.add((
        level: level,
        message: message,
        error: error,
        stack: stackTrace,
      ));
    };
    final stack = StackTrace.fromString(
      '#0 fixture (package:app/fixture.dart:1:1)',
    );
    const handler = ConsoleHandler(
      level: ReportLogLevel.error,
      enableDeviceParameters: true,
      enableApplicationParameters: true,
      enableCustomParameters: true,
    );
    expect(await handler.handle(_report(stack: stack)), isTrue);
    final event = events.single;
    expect(event.level, ReportLogLevel.error);
    expect(event.message.toString(), contains('fixture'));
    expect(event.error, 'fixture error');
    expect(event.stack, same(stack));
  });

  test(
    'string stacks become a typed stack without changing contents',
    () async {
      StackTrace? captured;
      Catcher2.logger = (level, message, {error, stackTrace}) =>
          captured = stackTrace;
      expect(
        await const ConsoleHandler().handle(_report(stack: 'fixture stack')),
        isTrue,
      );
      expect(captured.toString(), 'fixture stack');
    },
  );

  test(
    'absent host callback does not fabricate logging infrastructure',
    () async {
      expect(await const ConsoleHandler().handle(_report()), isTrue);
      expect(Catcher2.logger, isNull);
    },
  );

  test('null stack remains null', () {
    expect(ReportStackFormatter.formatStackString(null), isNull);
  });

  test(
    'application frames are preserved and internal async frames are elided',
    () {
      const stack =
          '#0 run (package:app/main.dart:10:2)\n'
          '#1 _rootRun (dart:async/zone.dart:1400:3)\n'
          '#2 dispatch (package:app/dispatch.dart:20:4)';
      expect(ReportStackFormatter.formatStackString(stack), [
        '#0 run (package:app/main.dart:10:2)',
        '#2 dispatch (package:app/dispatch.dart:20:4)',
        '(elided one frame from dart:async)',
      ]);
    },
  );

  test('method limit and explicit package filter are retained', () {
    const stack =
        '#0 run (package:app/main.dart:10:2)\n'
        '#1 dispatch (package:app/dispatch.dart:20:4)';
    expect(ReportStackFormatter.formatStackString(stack, 1), [
      '#0 run (package:app/main.dart:10:2)',
    ]);
    expect(ReportStackFormatter.formatStackString(stack, -1, ['package:app']), [
      '(elided 2 frames from package:app)',
    ]);
  });

  test('report JSON schema and readable stack remain available', () {
    const stack = '#0 run (package:app/main.dart:10:2)';
    final original = _report(stack: stack);
    final restored = Report.fromJson(
      original.toJson(enableCustomParameters: true),
    );
    expect(restored.error, original.error);
    expect(restored.stackTrace.toString(), stack);
    expect(restored.deviceParameters, original.deviceParameters);
    expect(restored.applicationParameters, original.applicationParameters);
    expect(restored.customParameters, original.customParameters);
    expect(restored.toString(), contains(stack));
  });
}
