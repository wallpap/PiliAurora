import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/src/image_source_store.dart';

void main() {
  late Directory directory;
  late File original;
  late ImageSourceStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('image-source-contract-');
    original = await File('${directory.path}/original.bin')
        .writeAsBytes([1, 2, 3]);
    store = ImageSourceStore(Directory('${directory.path}/snapshots'));
  });

  tearDown(() async {
    await store.clear();
    await directory.delete(recursive: true);
  });

  test(
    'active snapshots keep exact bytes when the original path changes',
    () async {
      final lease = await store.acquire(original);
      final version = lease.version;
      expect(lease.file.path, isNot(original.path));
      await original.writeAsBytes([4, 5, 6]);
      expect(await lease.file.readAsBytes(), [1, 2, 3]);
      expect(lease.version, version);
      await lease.dispose();
      expect(await original.readAsBytes(), [4, 5, 6]);
    },
  );

  test(
    'simultaneous and overlapping readers share the active version',
    () async {
      final leases = await Future.wait([
        store.acquire(original),
        store.acquire(original),
      ]);
      expect(leases[0].version, leases[1].version);
      expect(leases[0].file.path, leases[1].file.path);
      await leases[0].dispose();
      expect(await leases[1].file.exists(), isTrue);
      final later = await store.acquire(original);
      expect(later.version, leases[1].version);
      await leases[1].dispose();
      expect(await later.file.readAsBytes(), [1, 2, 3]);
      await later.dispose();
      final reopened = await store.acquire(original);
      expect(reopened.version, isNot(later.version));
      await reopened.dispose();
    },
  );

  test(
    'cache clearing defers active deletion and preserves user originals',
    () async {
      final lease = await store.acquire(original);
      await store.clear();
      expect(await lease.file.readAsBytes(), [1, 2, 3]);
      expect(await original.readAsBytes(), [1, 2, 3]);
      final snapshot = lease.file;
      await lease.dispose();
      await lease.dispose();
      expect(await snapshot.exists(), isFalse);
      expect(await original.exists(), isTrue);
    },
  );

  test('failed preparation does not poison subsequent acquisition', () async {
    final missing = File('${directory.path}/missing.bin');
    await expectLater(
      store.acquire(missing),
      throwsA(isA<FileSystemException>()),
    );
    await missing.writeAsBytes([9]);
    final lease = await store.acquire(missing);
    expect(await lease.file.readAsBytes(), [9]);
    await lease.dispose();
  });
}
