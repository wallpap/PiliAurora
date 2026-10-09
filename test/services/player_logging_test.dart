import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('player-log-'),
  );
  tearDown(() => directory.delete(recursive: true));

  test(
    'player level is independent, persisted, redacted and exported separately',
    () async {
      Map<String, Object?>? settings;
      final service = Diagnostics();
      await service.initialize(
        directory: directory,
        level: DiagnosticLogLevel.off,
        playerLevel: DiagnosticLogLevel.debug,
        saveSettings: (value) async => settings = value,
      );
      addTearDown(service.dispose);
      final storage = service.storageStatus;
      final runtime = storage['runtime'] as Map;
      final player = storage['player'] as Map;
      final performance = storage['performance'] as Map;
      expect(runtime['maxFileBytes'], 8 << 20);
      expect(runtime['retainedFiles'], 4);
      expect(player['maxFileBytes'], 16 << 20);
      expect(player['retainedFiles'], 8);
      expect(performance['maxFileBytes'], 16 << 20);
      expect(performance['retainedFiles'], 4);
      service
        ..log(DiagnosticLogLevel.error, 'app', 'disabled')
        ..playerLog(
          DiagnosticLogLevel.debug,
          'decoder',
          'fallback',
          details: {
            'playerId': 'p1',
            'generation': 2,
            'token': 'do-not-save',
          },
        )
        ..playerLog(DiagnosticLogLevel.trace, 'mpv', 'filtered');
      await service.flush();
      final files = await service.files();
      expect(
        files.map((file) => file.uri.pathSegments.last),
        contains('player.jsonl'),
      );
      expect(
        files.map((file) => file.uri.pathSegments.last),
        isNot(contains('runtime.jsonl')),
      );
      final records = await File('${directory.path}/player.jsonl')
          .readAsLines();
      expect(records, hasLength(1));
      final record = jsonDecode(records.single) as Map;
      expect(record['sequence'], isA<int>());
      expect(record['elapsedUs'], isA<int>());
      expect(record['runId'], isA<String>());
      expect(records.single, isNot(contains('do-not-save')));
      await service.configure(playerLevel: DiagnosticLogLevel.trace);
      expect(settings?['playerLevel'], 'trace');
      service.playerLog(
        DiagnosticLogLevel.trace,
        'mpv',
        'detail-${'x' * 12000}-tail',
        details: {
          'payload': 'context-${'y' * 12000}-end',
          'authorization': 'secret',
        },
      );
      final archiveFile = await service.exportArchive();
      try {
        final archive = ZipDecoder().decodeBytes(
          await archiveFile.readAsBytes(),
        );
        final playerFile = archive.files.singleWhere(
          (file) => file.name == 'player.jsonl',
        );
        final content = utf8.decode(playerFile.content);
        expect(content, contains('-tail'));
        expect(content, contains('-end'));
        expect(content, isNot(contains('do-not-save')));
        expect(content, isNot(contains('secret')));
        final manifest = jsonDecode(
          utf8.decode(
            archive.files
                .singleWhere((file) => file.name == 'manifest.json')
                .content,
          ),
        ) as Map;
        expect(manifest['playerLevel'], 'trace');
        expect(manifest['storage'], contains('player'));
      } finally {
        await archiveFile.parent.delete(recursive: true);
      }
      await service.clear();
      expect(await service.files(), isEmpty);
    },
  );
}
