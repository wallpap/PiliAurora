import 'dart:convert';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/raster_cache.dart';

const _option = DanmakuOption(fontSize: 20, duration: 2);
DanmakuContentItem<void> _item(int index) => DanmakuContentItem<void>(
  'x' * 64,
  color: Color(0xFF000001 + index),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('16/24/32 MiB capacity replay isolates LRU capacity from reuse', () {
    final probe = DanmakuRasterCache(option: _option, devicePixelRatio: 1.5);
    final itemBytes = probe.get(_item(0))!.bytes;
    probe.clear();
    final count = (28 * 1024 * 1024 + itemBytes - 1) ~/ itemBytes;
    expect(count, lessThanOrEqualTo(512));
    expect(count * itemBytes, lessThanOrEqualTo(32 * 1024 * 1024));
    final items = List.generate(count, _item);
    for (final capacity in [16, 24, 32]) {
      for (final workload in ['unique', 'repeated', 'prewarm-scan']) {
        final cache = DanmakuRasterCache(
          option: _option,
          devicePixelRatio: 1.5,
          maxBytes: capacity * 1024 * 1024,
        );
        try {
          if (workload == 'prewarm-scan') {
            for (final item in items) {
              cache.get(item, rasterize: true);
              expect(cache.bytes, lessThanOrEqualTo(cache.maxBytes));
            }
          }
          final before = cache.rasterizations;
          var demandImageHits = 0;
          for (var index = 0; index < count; index++) {
            final item = workload == 'repeated'
                ? items[index % 12]
                : items[index];
            if (cache.isRasterized(item)) demandImageHits++;
            cache.get(item, rasterize: true);
            expect(cache.bytes, lessThanOrEqualTo(cache.maxBytes));
          }
          final expectedHits = workload == 'repeated'
              ? count - 12
              : workload == 'prewarm-scan' && capacity == 32
              ? count
              : 0;
          expect(demandImageHits, expectedHits);
          expect(cache.rasterizations - before, count - expectedHits);
          expect(cache.evictedImages + cache.evictedLayouts, cache.evictions);
          debugPrint(
            'CACHE_CAPACITY_RESULT ${jsonEncode({
              'capacityMiB': capacity,
              'workload': workload,
              'count': count,
              'itemBytes': itemBytes,
              'demandImageHits': demandImageHits,
              'demandRasterizations': cache.rasterizations - before,
              'evictedImages': cache.evictedImages,
              'evictedLayouts': cache.evictedLayouts,
              'evictionsByBytes': cache.evictionsByBytes,
              'evictionsByEntries': cache.evictionsByEntries,
              'cacheImageBytes': cache.bytes,
            })}',
          );
        } finally {
          cache.clear();
        }
      }
    }
  });
}
