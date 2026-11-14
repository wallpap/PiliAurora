import 'native_fixture_support.dart';

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/image/image_resources.dart';
import 'package:pili_aurora/common/widgets/image/src/content_demand.dart';
import 'package:pili_aurora/common/widgets/image/src/image_source_store.dart';
import 'package:pili_aurora/common/widgets/image/src/native_worker_backend.dart';
import 'package:pili_aurora/common/widgets/image/src/region_content_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  observeNativeWorkers();
  nativeTest(
    'first visible progressive image scans once at sufficient sampling',
    () async {
      final fixtures = nativeFixtures;
      final file = File(
        fixtures.cast<Map>().singleWhere(
              (row) => row['id'] == 'progressive',
            )['file']
            as String,
      );
      final directory = await Directory.systemTemp.createTemp(
        'region-demand-base-',
      );
      final store = ImageSourceStore(Directory('${directory.path}/source'));
      final lease = await store.acquire(file);
      final decoder = await NativeWorkerDecoder.open(lease);
      final resources = ImageResources(maximumRegionBytes: 128 << 20);
      final session =
          RegionContentSession(
            source: lease,
            backend: PreparedNativeBackend(decoder),
            resources: resources,
            maximumBytes: 48 << 20,
            maximumBaseBytes: 32 << 20,
            coalesceViewport: true,
          )..update(
            const ContentDemand(
              viewport: ContentViewport(Rect.fromLTWH(0, 0, 6000, 4000), .3),
            ),
          );
      try {
        for (var i = 0; i < 300; i++) {
          if (session.value.images.isNotEmpty &&
              session.value.images.any(
                (image) => image.image.width / image.sourceRect.width >= .3,
              )) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final decodes = nativeWorkerEvents
            .where(
              (event) =>
                  event['pid'] == decoder.process.pid &&
                  event['event'] == 'decode',
            )
            .toList();
        expect(decodes, hasLength(1));
        expect(decodes.single['width'], 3000);
        expect(decodes.single['height'], 2000);
        expect(session.workingSetBytes, 3000 * 2000 * 4);
        session.update(
          const ContentDemand(
            viewport: ContentViewport(Rect.fromLTWH(1024, 1024, 512, 512), 1),
          ),
        );
        for (var i = 0; i < 300 && session.value.images.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(session.value.images.length, 2);
        expect(
          session.value.images.last.image.width /
              session.value.images.last.sourceRect.width,
          1,
        );
      } finally {
        session.dispose();
        await session.drained;
        resources.dispose();
        await resources.drained;
        expect(store.statistics['leases'], 0);
        expect(nativeWorkers, isEmpty);
        await store.clear();
        await directory.delete(recursive: true);
      }
    },
  );
}
