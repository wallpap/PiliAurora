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

  test(
    'acquisition reserves its snapshot before the last reader releases',
    () async {
      final first = await store.acquire(original);
      final pending = store.acquire(original);
      final releasing = first.dispose();
      final newer = await pending;
      await releasing;
      expect(newer.version, first.version);
      expect(await newer.file.readAsBytes(), [1, 2, 3]);
      await newer.dispose();
    },
  );

  test('clearing during acquisition preserves reserved and newly published snapshots', () async {
    final first = await store.acquire(original);
    final secondSource = await File('${directory.path}/second.bin')
        .writeAsBytes([8]);
    final pending = store.acquire(secondSource);
    final clearing = store.clear();
    final newer = await pending;
    await clearing;
    expect(await first.file.readAsBytes(), [1, 2, 3]);
    expect(await newer.file.readAsBytes(), [8]);
    await first.dispose();
    await newer.dispose();
  });

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

  test('clearing and final release have exactly one deletion owner', () async {
    final lease = await store.acquire(original);
    await Future.wait([store.clear(), lease.dispose(), store.clear()]);
    expect(await lease.file.exists(), isFalse);
    expect(await original.readAsBytes(), [1, 2, 3]);
  });

  test(
    'snapshot accounting counts shared bytes once and drains after release',
    () async {
      final leases = await Future.wait([
        store.acquire(original),
        store.acquire(original),
      ]);
      expect(store.statistics, containsPair('leases', 2));
      expect(store.statistics, containsPair('snapshots', 1));
      expect(store.statistics, containsPair('snapshotBytes', 3));
      await store.clear();
      expect(store.statistics['snapshotBytes'], 3);
      await leases[0].dispose();
      expect(store.statistics['leases'], 1);
      await leases[1].dispose();
      expect(store.statistics.values, everyElement(0));
    },
  );

  test('a retained task keeps its source after its surface closes', () async {
    final surface = await store.acquire(original);
    final task = surface.retain();
    expect(task.version, surface.version);
    expect(task.file.path, surface.file.path);
    await surface.dispose();
    expect(surface.retain, throwsStateError);
    await store.clear();
    expect(await task.file.readAsBytes(), [1, 2, 3]);
    expect(store.statistics['leases'], 1);
    await task.dispose();
    expect(await task.file.exists(), isFalse);
    expect(store.statistics.values, everyElement(0));
  });
}
