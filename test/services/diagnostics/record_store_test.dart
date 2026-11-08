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
  test('default store retains a 4096 record burst without dropping', () async {
    final store = DiagnosticRecordStore(File('${directory.path}/burst.jsonl'));
    for (var i = 0; i < 4096; i++) {
      store.add({'event': i});
    }
    await store.flush();
    expect(store.dropped, 0);
    expect(await store.file.readAsLines(), hasLength(4096));
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
