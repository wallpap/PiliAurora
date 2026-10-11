import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/record_store.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pili-diagnostic-store-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('records rotate and recover after a failed write', () async {
    final file = File('${directory.path}/bounded.jsonl');
    final store = DiagnosticRecordStore(
      file,
      maxBytes: 140,
      retainedFiles: 2,
      maxPending: 8,
    );
    for (var i = 0; i < 10; i++) {
      store.add({'message': 'record-$i-${'x' * 40}'});
      await store.flush();
    }
    final files = await store.files();
    expect(files.length, lessThanOrEqualTo(2));
    for (final file in files) {
      expect(await file.length(), lessThanOrEqualTo(140));
    }
    expect(await file.readAsString(), contains('record-9'));
    final blocker = File('${directory.path}/blocked');
    await blocker.writeAsString('not a directory');
    final recoverable = DiagnosticRecordStore(
      File('${blocker.path}/log.jsonl'),
    )..add({'message': 'fails'});
    await recoverable.flush();
    expect(recoverable.dropped, 1);
    await blocker.delete();
    recoverable.add({'message': 'recovers'});
    await recoverable.flush();
    expect(await recoverable.file.readAsString(), contains('recovers'));
  });

  test(
    'slow writers drop excess work without retaining an unbounded queue',
    () async {
      final store = DiagnosticRecordStore(
        File('${directory.path}/queue.jsonl'),
        maxPending: 2,
      );
      for (var i = 0; i < 100; i++) {
        store.add({'index': i});
      }
      expect(store.dropped, 98);
      await store.flush();
      expect(await store.file.readAsLines(), hasLength(2));
    },
  );
}
