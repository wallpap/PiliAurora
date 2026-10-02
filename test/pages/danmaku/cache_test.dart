import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/cache.dart';
import 'package:flutter_test/flutter_test.dart';

DanmakuElem _element(int progress, int id) => DanmakuElem(
  progress: progress,
  content: '弹幕$id',
);

void main() {
  test(
    'lookahead respects bounds and limit without changing eviction order',
    () {
      final cache = DanmakuCache(maxSegments: 2)
        ..addSegmentBuckets(0, {
          0: [_element(0, 0)],
          1: [_element(100, 1), _element(150, 2)],
          2: [_element(200, 3)],
        })
        ..addSegmentBuckets(1, {
          3600: [_element(360000, 4)],
        });
      expect(cache.peekRange(100, 200).map((element) => element.progress), [
        100,
        150,
      ]);
      expect(
        cache.peekRange(100, 201, limit: 1).map((element) => element.progress),
        [100],
      );
      expect(cache.peekRange(0, 100, limit: 0), isEmpty);
      cache.addSegmentBuckets(2, {});
      expect(cache.containsSegment(0), isFalse);
      expect(cache.containsSegment(1), isTrue);
    },
  );
  test('high density segment remains cached without repeated reload', () {
    final cache = DanmakuCache(
      maxBuckets: 10,
      maxElements: 12,
      maxElementsPerBucket: 3,
    );
    // ignore: cascade_invocations
    cache
      ..addSegmentBuckets(0, {
        0: List.generate(100, (i) => _element(0, i)),
        1: [_element(100, 101)],
      })
      ..addSegmentBuckets(0, {
        0: [_element(0, 999)],
      });

    expect(cache.containsSegment(0), isTrue);
    expect(cache.elementCount, 4);
    expect(cache.getAt(0), hasLength(3));
    expect(cache.getAt(100), hasLength(1));
    expect(cache.getAt(0), hasLength(3));
  });

  test('eviction removes a complete old segment', () {
    final cache = DanmakuCache(
      maxBuckets: 2,
      maxElements: 3,
      maxElementsPerBucket: 3,
    );
    // ignore: cascade_invocations
    cache
      ..addSegmentBuckets(0, {
        0: [_element(0, 0)],
        1: [_element(100, 1)],
      })
      ..addSegmentBuckets(1, {
        3600: [_element(360000, 2)],
        3601: [_element(360100, 3)],
      });

    expect(cache.containsSegment(0), isFalse);
    expect(cache.containsSegment(1), isTrue);
    expect(cache.bucketCount, 2);
    expect(cache.elementCount, 2);
    expect(cache.getAt(0), isNull);
    expect(cache.getAt(360000), hasLength(1));
  });

  test('empty segment is marked loaded until eviction', () {
    final cache = DanmakuCache(
      maxBuckets: 1,
      maxElements: 1,
      maxSegments: 1,
    );
    // ignore: cascade_invocations
    cache.addSegmentBuckets(0, {});
    expect(cache.containsSegment(0), isTrue);
    cache
      ..addSegmentBuckets(1, {
        3600: [_element(360000, 1)],
      })
      ..addSegmentBuckets(2, {
        7200: [_element(720000, 2)],
      });

    expect(cache.containsSegment(0), isFalse);
    expect(cache.containsSegment(1), isFalse);
    expect(cache.containsSegment(2), isTrue);
  });

  test('local file elements are retained without network limits', () {
    final cache = DanmakuCache(
      maxBuckets: 1,
      maxElements: 1,
      maxElementsPerBucket: 1,
    );
    // ignore: cascade_invocations
    cache.addFileElements([
      _element(0, 0),
      _element(0, 1),
      _element(360000, 2),
    ]);

    expect(cache.getAt(0), hasLength(2));
    expect(cache.getAt(360000), hasLength(1));
    expect(cache.elementCount, 3);
  });
}
