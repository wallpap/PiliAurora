import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Diagnostics diagnostics;
  var reads = 0;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pili-diagnostics-test-');
    reads = 0;
    diagnostics = Diagnostics(
      processReader: () {
        reads++;
        return {'rssBytes': 123456, 'privateBytes': null};
      },
    );
    await diagnostics.initialize(directory: directory);
  });
  tearDown(() async {
    diagnostics.dispose();
    await diagnostics.flush();
    await directory.delete(recursive: true);
  });

  test('levels change immediately and recent logs stay bounded', () async {
    diagnostics.log(DiagnosticLogLevel.debug, 'test', 'hidden');
    expect(diagnostics.recentLogs, isEmpty);
    await diagnostics.configure(level: DiagnosticLogLevel.debug);
    for (var i = 0; i < 250; i++) {
      diagnostics.log(DiagnosticLogLevel.debug, 'test', 'record $i');
    }
    expect(diagnostics.recentLogs, hasLength(200));
    expect(diagnostics.recentLogs.first['message'], 'record 249');
    await diagnostics.configure(level: DiagnosticLogLevel.off);
    diagnostics.log(DiagnosticLogLevel.error, 'test', 'hidden error');
    expect(diagnostics.recentLogs.first['message'], 'record 249');
  });

  test(
    'tracking is opt in and snapshots include current module data',
    () async {
      diagnostics.capture();
      expect(reads, 0);
      final detach = diagnostics.register(
        'player',
        () => {'width': 1920, 'buffering': true},
      );
      await diagnostics.configure(tracing: true, intervalMs: 250);
      diagnostics.begin('http', 'GET')!
        ..finish()
        ..finish();
      diagnostics.capture();
      expect(diagnostics.latest!['process'], containsPair('rssBytes', 123456));
      expect(
        (diagnostics.latest!['operations'] as Map)['http'],
        containsPair('completed', 1),
      );
      expect(
        (diagnostics.latest!['sources'] as Map)['player'],
        containsPair('width', 1920),
      );
      detach();
      diagnostics.capture();
      expect(diagnostics.latest!['sources'], isEmpty);
      await diagnostics.configure(tracing: false);
      final stoppedReads = reads;
      diagnostics.capture();
      expect(reads, stoppedReads);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(reads, stoppedReads);
    },
  );

  test(
    'settings and bounded history survive a restart, then can be cleared',
    () async {
      Map<String, Object?> settings = {};
      final first = Diagnostics(processReader: () => {});
      await first.initialize(
        directory: directory,
        saveSettings: (value) async => settings = value,
      );
      await first.configure(
        tracing: true,
        level: DiagnosticLogLevel.debug,
        intervalMs: 250,
      );
      for (var i = 0; i < 205; i++) {
        first.log(DiagnosticLogLevel.info, 'test', 'history $i');
      }
      first.dispose();
      await first.flush();
      await File('${directory.path}/runtime.jsonl').writeAsString(
        'incomplete record\n',
        mode: FileMode.append,
      );
      final restored = Diagnostics(processReader: () => {});
      try {
        await restored.initialize(
          directory: directory,
          level: DiagnosticLogLevel.parse(settings['level'] as String),
          tracing: settings['tracing'] as bool,
          intervalMs: settings['intervalMs'] as int,
        );
        expect(restored.level, DiagnosticLogLevel.debug);
        expect(restored.tracing, isTrue);
        expect(restored.intervalMs, 250);
        expect(restored.recentLogs, hasLength(200));
        expect(restored.recentLogs.first['message'], 'history 204');
        expect(restored.recentLogs.last['message'], 'history 5');
        await restored.clear();
        expect(restored.tracing, isFalse);
        expect(restored.recentLogs, isEmpty);
        expect(await restored.files(), isEmpty);
        restored.log(DiagnosticLogLevel.error, 'test', 'after clear');
        await restored.flush();
        expect(await restored.files(), hasLength(1));
      } finally {
        restored.dispose();
        await restored.flush();
      }
    },
  );

  test(
    'export contains readable sanitized logs and performance records',
    () async {
      await diagnostics.configure(
        tracing: true,
        level: DiagnosticLogLevel.debug,
      );
      diagnostics.log(
        DiagnosticLogLevel.debug,
        'test',
        "token=export-secret-test\nAudio 'track.m4s?e=export-signed-query&mid=export-user-id' (aac)",
      );
      final file = await diagnostics.exportArchive();
      try {
        final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
        expect(
          archive.files.map((file) => file.name),
          containsAll(['runtime.jsonl', 'performance.jsonl', 'manifest.json']),
        );
        for (final entry in archive.files) {
          final content = utf8.decode(entry.content);
          expect(content, isNot(contains('export-secret-test')));
          expect(content, isNot(contains('export-signed-query')));
          expect(content, isNot(contains('export-user-id')));
          for (final line in const LineSplitter().convert(content)) {
            expect(jsonDecode(line), isA<Map>());
          }
        }
      } finally {
        await file.parent.delete(recursive: true);
      }
    },
  );
}
