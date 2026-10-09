import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/record_store.dart';

void main() {
  late Directory directory;
  setUp(
    () async => directory = await Directory.systemTemp.createTemp('log-burst-'),
  );
  tearDown(() => directory.delete(recursive: true));
  test('default store retains a 4096 record burst without dropping', () async {
    final store = DiagnosticRecordStore(File('${directory.path}/burst.jsonl'));
    for (var i = 0; i < 4096; i++) {
      store.add({'event': i});
    }
    await store.flush();
    expect(store.dropped, 0);
    expect(await store.file.readAsLines(), hasLength(4096));
    expect(store.maxBytes, 8 << 20);
    expect(store.retainedFiles, 4);
  });

  test(
    'byte budget and oversized records have explicit drop reasons',
    () async {
      final store = DiagnosticRecordStore(
        File('${directory.path}/budget.jsonl'),
        maxPendingBytes: 256,
        maxRecordBytes: 128,
      );
      expect(store.add({'message': 'x' * 100}), isTrue);
      expect(store.add({'message': 'x' * 100}), isTrue);
      expect(store.add({'message': 'x' * 100}), isFalse);
      expect(store.add({'message': 'x' * 200}), isFalse);
      await store.flush();
      expect(store.dropReasons, {'queue-full': 1, 'record-too-large': 1});
      expect(store.status['pendingBytes'], 0);
    },
  );
  test('batched rotation keeps strict limits and reports eviction', () async {
    final store = DiagnosticRecordStore(
      File('${directory.path}/rotate.jsonl'),
      maxBytes: 128,
      retainedFiles: 2,
    );
    for (var i = 0; i < 20; i++) {
      store.add({'index': i, 'message': 'x' * 50});
    }
    await store.flush();
    expect(store.dropped, 0);
    expect(store.rotations, greaterThan(0));
    expect(store.evictedFiles, greaterThan(0));
    for (final file in await store.files()) {
      expect(await file.length(), lessThanOrEqualTo(128));
    }
    expect(await store.file.readAsString(), contains('"index":19'));
  });
}
