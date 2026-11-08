import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
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

  for (final (threshold, expected) in [
    (DiagnosticLogLevel.trace, ['error', 'warning', 'info', 'debug']),
    (DiagnosticLogLevel.debug, ['error', 'warning', 'info', 'debug']),
    (DiagnosticLogLevel.info, ['error', 'warning', 'info']),
    (DiagnosticLogLevel.warning, ['error', 'warning']),
    (DiagnosticLogLevel.error, ['error']),
    (DiagnosticLogLevel.off, <String>[]),
  ]) {
    test(
      'console and persisted records follow the $threshold threshold',
      () async {
        await diagnostics.configure(level: threshold);
        logAll();
        expect(
          diagnostics.recentLogs.map((record) => record['level']),
          expected,
        );
        expect(console, hasLength(expected.length));
        await diagnostics.flush();
        final file = File('${directory.path}/runtime.jsonl');
        final persisted = file.existsSync()
            ? file.readAsLinesSync()
            : <String>[];
        expect(
          persisted.map((line) => (jsonDecode(line) as Map)['level']),
          expected.reversed,
        );
      },
    );
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
    'structured messages, errors and stacks stay raw locally and redact on export',
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
        expect(output, contains('fixture-password'));
        expect(output, contains('fixture-key'));
        expect(output, contains('fixture-stack'));
      }
      final archiveFile = await diagnostics.exportArchive();
      try {
        final archive = ZipDecoder().decodeBytes(
          await archiveFile.readAsBytes(),
        );
        final output = utf8.decode(
          archive.files.firstWhere((f) => f.name == 'runtime.jsonl').content,
        );
        expect(output, isNot(contains('fixture-password')));
        expect(output, isNot(contains('fixture-key')));
        expect(output, isNot(contains('fixture-stack')));
        expect(output, contains('<redacted>'));
        expect(output, contains('ready'));
        expect(output, contains('500'));
      } finally {
        await archiveFile.parent.delete(recursive: true);
      }
    },
  );

  test('console uses the current record even when remote clocks are ahead', () {
    diagnostics.receiveRecord({
      'time': '2100-01-01T00:00:00.000Z',
      'level': 'error',
      'channel': 'runtime',
      'message': 'remote clock',
    }, windowId: 1);
    logger.w('current message');
    expect(console.single, contains('current message'));
    expect(console.single, isNot(contains('remote clock')));
  });

  test('scoped logger preserves its module category', () {
    logger.scoped('network').w('request failed');
    expect(diagnostics.recentLogs.single['category'], 'network');
  });

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
