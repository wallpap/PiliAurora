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
    'reports share runtime storage, redaction and level filtering',
    () async {
      await diagnostics.initialize(directory: directory);
      final handler = DiagnosticReportHandler(diagnostics: diagnostics);
      final report = Report(
        'fixture error',
        'fixture stack',
        DateTime(2026),
        const {'token': 'fixture-secret'},
        const {'version': '1'},
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
      expect(content, contains('<redacted>'));
      expect(content, isNot(contains('fixture-secret')));
      await diagnostics.configure(level: DiagnosticLogLevel.off);
      expect(await handler.handle(report), isTrue);
      expect(diagnostics.recentLogs, hasLength(1));
    },
  );

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
    final archiveFile = await diagnostics.exportArchive();
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
      await archiveFile.parent.delete(recursive: true);
    }
    await diagnostics.clear();
    expect(diagnostics.recentLogs, isEmpty);
    expect(legacy.existsSync() ? legacy.lengthSync() : 0, 0);
  });
}
