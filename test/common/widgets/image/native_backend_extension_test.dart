import 'native_fixture_support.dart';

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/image_resources.dart';
import 'package:pili_aurora/common/widgets/image/src/content_demand.dart';
import 'package:pili_aurora/common/widgets/image/src/image_source_store.dart';
import 'package:pili_aurora/common/widgets/image/src/region_content_session.dart';
import 'package:pili_aurora/common/widgets/image/src/native_worker_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  observeNativeWorkers();
  final fixtures = nativeFixtures;
  File fixture(String id) => File(
    (fixtures.cast<Map>().singleWhere((e) => e['id'] == id))['file'] as String,
  );
  late Directory directory;
  late ImageSourceStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'region-native-contract-',
    );
    store = ImageSourceStore(Directory('${directory.path}/snapshots'));
  });
  tearDown(() async {
    await store.clear();
    await directory.delete(recursive: true);
    expect(nativeWorkers, isEmpty);
  });
  nativeTest('native base publishes bounded ui.Image and keeps source until process exit', () async {
    final lease = await store.acquire(fixture('wide'));
    final snapshot = lease.file;
    final decoder = await NativeWorkerDecoder.open(lease);
    await lease.dispose();
    expect(snapshot.existsSync(), isTrue);
    final base = await decoder.decodeBase(1 << 20);
    expect(base.bytes, lessThanOrEqualTo(4 << 20));
    expect(base.sourceRect, Offset.zero & decoder.sourceSize);
    base.dispose();
    decoder.dispose();
    await decoder.drained;
    expect(snapshot.existsSync(), isFalse);
    expect(store.statistics['leases'], 0);
  });
  nativeTest(
    'oversized global WebP scale reports capability fallback before decoding',
    () async {
      final lease = await store.acquire(fixture('huge-webp'));
      final decoder = await NativeWorkerDecoder.open(lease);
      await lease.dispose();
      try {
        await expectLater(
          decoder.decodeRegion(
            const RegionRequest(
              level: 1,
              core: Rect.fromLTWH(0, 0, 600, 400),
              read: Rect.fromLTWH(0, 0, 604, 404),
            ),
          ),
          throwsUnsupportedError,
        );
        expect(
          nativeWorkerEvents.where((event) => event['event'] == 'decode'),
          isEmpty,
        );
      } finally {
        decoder.dispose();
        await decoder.drained;
      }
      expect(store.statistics['leases'], 0);
    },
  );
  nativeTest(
    'prepared decoder closes when hidden session never asks for pixels',
    () async {
      final lease = await store.acquire(fixture('wide'));
      final decoder = await NativeWorkerDecoder.open(lease);
      final resources = ImageResources();
      final session = RegionContentSession(
        source: lease,
        backend: PreparedNativeBackend(decoder),
        resources: resources,
      )..dispose();
      try {
        await session.drained.timeout(const Duration(seconds: 2));
        expect(nativeWorkers, isEmpty);
        expect(store.statistics['leases'], 0);
      } finally {
        decoder.dispose();
        await decoder.drained;
        resources.dispose();
        await resources.drained;
      }
    },
  );
  nativeTest(
    'real native cancellation drains process and its retained source',
    () async {
      final lease = await store.acquire(fixture('progressive'));
      final decoder = await NativeWorkerDecoder.open(lease);
      final resources = ImageResources();
      final session =
          RegionContentSession(
            source: lease,
            backend: PreparedNativeBackend(decoder),
            resources: resources,
            maximumBytes: 48 << 20,
            coalesceViewport: true,
          )..update(
            const ContentDemand(
              viewport: ContentViewport(Rect.fromLTWH(0, 0, 1900, 1144), 1),
            ),
          );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      session.dispose();
      await session.drained;
      expect(resources.regionBytes, 0);
      expect(store.statistics['leases'], 0);
      expect(await decoder.process.exitCode, 0);
      resources.dispose();
      await resources.drained;
    },
  );
  nativeTest(
    'native rejection drains worker before decode error releases source',
    () async {
      final lease = await store.acquire(fixture('progressive'));
      final decoder = await NativeWorkerDecoder.open(lease);
      await lease.dispose();
      // 96MB完整帧超过普通协议40MiB容量，必须错误退出且释放真实worker租约。
      final drain = decoder.drained.then<Object?>(
        (_) => null,
        onError: (Object e, StackTrace s) => e,
      );
      await expectLater(
        decoder.decodeRegion(
          const RegionRequest(
            level: 0,
            core: Rect.fromLTWH(0, 0, 6000, 4000),
            read: Rect.fromLTWH(0, 0, 6000, 4000),
          ),
        ),
        throwsStateError,
      );
      expect(nativeWorkers, isEmpty);
      expect(store.statistics['leases'], 0);
      expect(await drain, isNull);
    },
  );
  nativeTest(
    'unexpected worker death still drains an active decode and source',
    () async {
      final lease = await store.acquire(fixture('progressive'));
      final decoder = await NativeWorkerDecoder.open(lease);
      await lease.dispose();
      final drain = decoder.drained.then<Object?>(
        (_) => null,
        onError: (Object e, StackTrace s) => e,
      );
      final request = decoder.decodeRegion(
        const RegionRequest(
          level: 0,
          core: Rect.fromLTWH(0, 0, 1900, 1144),
          read: Rect.fromLTWH(0, 0, 1900, 1144),
        ),
      );
      decoder.process.kill();
      await expectLater(request, throwsA(anything));
      expect(nativeWorkers, isEmpty);
      expect(store.statistics['leases'], 0);
      expect(await drain, isNotNull);
    },
  );
  nativeTest('corrupt header releases only its own retain', () async {
    final file = await File('${directory.path}/invalid')
        .writeAsBytes([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
    final lease = await store.acquire(file);
    await expectLater(NativeWorkerDecoder.open(lease), throwsStateError);
    expect(store.statistics['leases'], 1);
    await lease.dispose();
    expect(store.statistics['leases'], 0);
  });
}
