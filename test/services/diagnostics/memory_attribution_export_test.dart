import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/redact.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('export includes a session scoped attribution summary while app logging is off', () async {
    final directory = await Directory.systemTemp.createTemp(
      'memory-attribution-export-',
    );
    var bytes = 100;
    final diagnostics = Diagnostics(
      processReader: () => {'privateBytes': bytes},
    );
    await diagnostics.initialize(directory: directory);
    try {
      await diagnostics.configure(tracing: true, level: DiagnosticLogLevel.off);
      final unregister = diagnostics.register(
        'player.1',
        () => {
          'session': {'runtimeId': 7},
          'media': 'https://example.test/private?token=must-not-export',
        },
      );
      bytes = 300;
      diagnostics.capture();
      unregister();
      bytes = 180;
      diagnostics.capture();
      await diagnostics.configure(tracing: false);
      final exported = await diagnostics.exportArchive();
      try {
        final archive = ZipDecoder().decodeBytes(
          await exported.file.readAsBytes(),
        );
        final summary = jsonDecode(
          utf8.decode(
            archive.files
                .firstWhere((file) => file.name == 'memory-summary.json')
                .content,
          ),
        ) as Map;
        expect(summary['status'], 'observed');
        final session = (summary['sessions'] as List).single as Map;
        expect(session['processId'], pid);
        final stage = (session['stages'] as List).cast<Map>().singleWhere(
          (row) => row['stage'] == 'playback.closed',
        );
        expect(stage['runtimeId'], 7);
        expect(stage['privateDeltaBytes'], 80);
        expect(jsonEncode(summary), isNot(contains('must-not-export')));
        expect(exported.skippedRecords, 0);
        for (final file in archive.files) {
          expect(utf8.decode(file.content), isNot(contains('must-not-export')));
        }
      } finally {
        await exported.dispose();
      }
      await diagnostics.configure(tracing: true);
      final next = await diagnostics.exportArchive();
      try {
        final archive = ZipDecoder().decodeBytes(await next.file.readAsBytes());
        final summary = jsonDecode(
          utf8.decode(
            archive.files
                .firstWhere((file) => file.name == 'memory-summary.json')
                .content,
          ),
        ) as Map;
        expect(summary['sessions'], hasLength(2));
      } finally {
        await next.dispose();
      }
    } finally {
      diagnostics.dispose();
      await diagnostics.flush();
      await directory.delete(recursive: true);
    }
  });

  test(
    'eight native owners survive collection and export redaction independently',
    () {
      final resources = {
        for (var index = 0; index < 8; index++)
          'resource$index': {
            'count': 1,
            'created': 2,
            'released': 1,
            'estimatedBytes': 1024,
          },
      };
      final native = {
        'status': 'ok',
        'resources': resources,
        'omittedOwners': 0,
        'owners': [
          for (var index = 1; index <= 8; index++)
            {
              'ownerId': index,
              'runtimeId': index,
              'loadId': 1,
              'resources': resources,
              'token': 'native-owner-secret',
            },
        ],
      };
      final snapshot = DiagnosticRedactor.snapshotNativeMemory(native);
      expect((snapshot['owners'] as List).last, containsPair('ownerId', 8));
      expect(jsonEncode(snapshot), isNot(contains('<truncated>')));
      final exported = DiagnosticRedactor.exportRecord({
        'type': 'sample',
        'nativeMemory': snapshot,
      });
      final owners = (exported['nativeMemory'] as Map)['owners'] as List;
      expect(owners, hasLength(8));
      expect((owners.last as Map)['resources'], hasLength(8));
      expect(jsonEncode(exported), isNot(contains('native-owner-secret')));
      expect(jsonEncode(exported), isNot(contains('<truncated>')));
      final attribution = DiagnosticRedactor.exportRecord({
        'type': 'memoryAttribution',
        'owners': {
          'plugin.video': {
            'status': 'ok',
            'outputs': snapshot['owners'],
            'resources': resources,
          },
        },
      });
      expect(jsonEncode(attribution), isNot(contains('<truncated>')));
      expect(jsonEncode(attribution), isNot(contains('native-owner-secret')));
    },
  );
}
