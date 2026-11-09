import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:catcher_2/catcher_2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/report_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Diagnostics diagnostics;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pili-report-test-');
    diagnostics = Diagnostics();
  });
  tearDown(() async {
    diagnostics.dispose();
    await diagnostics.flush();
    await directory.delete(recursive: true);
  });

  test(
    'reports share runtime storage and redact on export',
    () async {
      await diagnostics.initialize(directory: directory);
      final handler = DiagnosticReportHandler(diagnostics: diagnostics);
      final report = Report(
        'fixture error',
        'fixture stack',
        DateTime(2026),
        const {
          'token': 'fixture-secret',
          'id': 'fixture-id',
          'fingerprint': 'fixture-fingerprint',
          'identifierForVendor': 'fixture-vendor',
          'model': 'fixture-model',
        },
        const {'version': '1', 'token': 'fixture-app-token'},
        const {'commit': 'fixture'},
        null,
      );
      expect(await handler.handle(report), isTrue);
      final record = diagnostics.recentLogs.single;
      expect(record['channel'], 'runtime');
      expect(record['category'], 'exception');
      expect(record['stack'], 'fixture stack');
      final content = await File('${directory.path}/runtime.jsonl')
          .readAsString();
      expect(content, contains('fixture-app-token'));
      final exportResult = await diagnostics.exportArchive();
      final output = exportResult.file;
      late String exported;
      try {
        final archive = ZipDecoder().decodeBytes(await output.readAsBytes());
        exported = utf8.decode(
          archive.files.firstWhere((f) => f.name == 'runtime.jsonl').content,
        );
      } finally {
        await exportResult.dispose();
      }
      expect(exported, contains('<redacted>'));
      expect(exported, isNot(contains('fixture-secret')));
      expect(exported, isNot(contains('fixture-id')));
      expect(exported, isNot(contains('fixture-fingerprint')));
      expect(exported, isNot(contains('fixture-vendor')));
      expect(exported, isNot(contains('fixture-app-token')));
      expect(content, contains('fixture-model'));
      await diagnostics.configure(level: DiagnosticLogLevel.off);
      expect(await handler.handle(report), isFalse);
      expect(diagnostics.recentLogs, hasLength(1));
    },
  );

  test(
    'report without persistent storage is not reported as delivered',
    () async {
      final handler = DiagnosticReportHandler(diagnostics: diagnostics);
      final report = Report(
        'error',
        'stack',
        DateTime(2026),
        const {},
        const {},
        const {},
        null,
      );
      expect(await handler.handle(report), isFalse);
    },
  );

  test('paused report waits for its eventual persistence result', () async {
    await diagnostics.initialize(directory: directory);
    await diagnostics.pauseWrites();
    final handler = DiagnosticReportHandler(diagnostics: diagnostics);
    final report = Report(
      'paused error',
      'stack',
      DateTime(2026),
      const {},
      const {},
      const {},
      null,
    );
    var complete = false;
    final result = handler.handle(report).then((value) {
      complete = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(complete, isFalse);
    diagnostics.resumeWrites();
    expect(await result, isTrue);
    expect(
      await File('${directory.path}/runtime.jsonl').readAsString(),
      contains('paused error'),
    );
    await diagnostics.pauseWrites();
    final cleared = handler.handle(report);
    await diagnostics.clearPausedRecords();
    diagnostics.resumeWrites();
    expect(await cleared, isFalse);
  });

  test('legacy reports remain readable, exportable and clearable', () async {
    final legacy = File('${directory.path}/.pili_logs.json');
    final report = Report(
      'old error',
      'old stack',
      DateTime(2026),
      const {'token': 'legacy-secret-fixture'},
      const {},
      const {},
      null,
    );
    await legacy.writeAsString('${jsonEncode(report.toJson())}\n');
    await diagnostics.initialize(directory: directory, legacyReports: legacy);
    expect(diagnostics.recentLogs.single['message'], 'old error');
    expect(diagnostics.recentLogs.single['stack'], 'old stack');
    final exportResult = await diagnostics.exportArchive();
    final archiveFile = exportResult.file;
    try {
      final archive = ZipDecoder().decodeBytes(await archiveFile.readAsBytes());
      expect(
        archive.files.any((file) => file.name == '.pili_logs.json'),
        isTrue,
      );
      final exported = utf8.decode(
        archive.files
                .firstWhere((file) => file.name == '.pili_logs.json')
                .content
            as List<int>,
      );
      expect(exported, contains('<redacted>'));
      expect(exported, isNot(contains('legacy-secret-fixture')));
      expect(await legacy.readAsString(), contains('legacy-secret-fixture'));
    } finally {
      await exportResult.dispose();
    }
    await diagnostics.clear();
    expect(diagnostics.recentLogs, isEmpty);
    expect(legacy.existsSync() ? legacy.lengthSync() : 0, 0);
  });
}
