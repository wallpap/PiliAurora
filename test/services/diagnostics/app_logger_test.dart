import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/app_logger.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

class _UnformattedMessage {
  int reads = 0;

  @override
  String toString() {
    reads++;
    return 'message';
  }
}

void main() {
  late Directory directory;
  late Diagnostics diagnostics;
  late AppLogger logger;
  late List<String> console;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pili-app-logger-');
    diagnostics = Diagnostics();
    await diagnostics.initialize(
      directory: directory,
      level: DiagnosticLogLevel.debug,
    );
    console = [];
    logger = AppLogger(diagnostics: diagnostics, console: console.add);
  });

  tearDown(() async {
    diagnostics.dispose();
    await diagnostics.flush();
    await directory.delete(recursive: true);
  });

  void logAll() {
    logger
      ..d('debug')
      ..i('info')
      ..w('warning')
      ..e('error');
  }

  test('all used log methods reach the same diagnostics category', () {
    logAll();
    expect(
      diagnostics.recentLogs.map((record) => record['level']),
      ['error', 'warning', 'info', 'debug'],
    );
    expect(
      diagnostics.recentLogs.every((record) => record['category'] == 'app'),
      isTrue,
    );
    expect(console, hasLength(4));
  });

  for (final threshold in DiagnosticLogLevel.values) {
    test('console and persistence share the $threshold threshold', () async {
      await diagnostics.configure(level: threshold);
      logAll();
      final accepted = [
        DiagnosticLogLevel.debug,
        DiagnosticLogLevel.info,
        DiagnosticLogLevel.warning,
        DiagnosticLogLevel.error,
      ].where(diagnostics.accepts).toList();
      expect(diagnostics.recentLogs, hasLength(accepted.length));
      expect(console, hasLength(accepted.length));
    });
  }

  test('filtered messages are never formatted', () async {
    await diagnostics.configure(level: DiagnosticLogLevel.off);
    final message = _UnformattedMessage();
    logger.e(message, error: message);
    expect(message.reads, 0);
    expect(console, isEmpty);
    expect(diagnostics.recentLogs, isEmpty);
  });

  test(
    'structured messages, errors and stack traces are redacted everywhere',
    () async {
      logger.e(
        {'password': 'fixture-password', 'state': 'ready'},
        error: {'api_key': 'fixture-key', 'status': 500},
        stackTrace: StackTrace.fromString(
          'https://example.test/fail?token=fixture-stack',
        ),
      );
      await diagnostics.flush();
      final persisted = await File('${directory.path}/runtime.jsonl')
          .readAsString();
      for (final output in [
        console.join('\n'),
        persisted,
        jsonEncode(diagnostics.recentLogs),
      ]) {
        expect(output, isNot(contains('fixture-password')));
        expect(output, isNot(contains('fixture-key')));
        expect(output, isNot(contains('fixture-stack')));
        expect(output, contains('<redacted>'));
        expect(output, contains('ready'));
        expect(output, contains('500'));
      }
      final record = diagnostics.recentLogs.single;
      expect(record['details'], {'api_key': '<redacted>', 'status': 500});
      expect(record['stack'], contains('https://example.test/fail?<redacted>'));
    },
  );

  test('release-style logger stores errors without a console', () {
    AppLogger(diagnostics: diagnostics)
        .w('request failed', error: 'socket closed');
    expect(console, isEmpty);
    final record = diagnostics.recentLogs.single;
    expect(record['message'], 'request failed');
    expect(record['details'], 'socket closed');
  });

  test('null message and omitted details do not fabricate fields', () {
    logger.i(null);
    final record = diagnostics.recentLogs.single;
    expect(record.containsKey('details'), isFalse);
    expect(record.containsKey('stack'), isFalse);
    expect(console.single, contains('info:'));
  });
}
