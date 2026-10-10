import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/sub/sub/data.dart';
import 'package:pili_aurora/models/remote/sub/sub/list.dart';
import 'package:pili_aurora/pages/subscription/cleanup.dart';

void main() {
  group('subscription cleanup', () {
    late List<(int?, int?)> cancelled;
    late Map<(int?, int?), Set<(int, int)>> hidden;
    late Map<int, LoadingState<bool>> videoStates;
    late Map<(int?, int), LoadingState<SubscriptionContentPage>> pages;
    late SubscriptionCleaner cleaner;
    late List<(int?, int)> requests;
    late List<int> checks;
    bool cancelFails = false;

    SubItemModel subscription(int id, {int type = 21, int state = 0}) =>
        SubItemModel(id: id, type: type, state: state);
    LoadingState<SubscriptionContentPage> contents(
      List<SubscriptionMedia> items, {
      bool hasMore = false,
    }) => Success(SubscriptionContentPage(items: items, hasMore: hasMore));

    setUp(() {
      cancelled = [];
      hidden = {};
      videoStates = {};
      pages = {};
      requests = [];
      checks = [];
      cancelFails = false;
      cleaner = SubscriptionCleaner(
        loadContents: (item, page) async {
          requests.add((item.id, page));
          return pages[(item.id, page)] ?? const Error('missing page');
        },
        checkVideo: (aid) async {
          checks.add(aid);
          return videoStates[aid] ?? const Error('unknown video');
        },
        cancel: (item) async {
          if (cancelFails) return const Error('取消失败');
          cancelled.add((item.type, item.id));
          return const Success(null);
        },
        saveHidden: (item, media) async {
          hidden[(item.type, item.id)] = Set.of(media);
          return media.length;
        },
      );
    });

    test(
      'cancels explicitly invalid folders and seasons without reading contents',
      () async {
        final result = await cleaner.run([
          subscription(1, type: 11, state: 1),
          subscription(2, state: 1),
        ], hideInvalid: false);
        expect(cancelled, [(11, 1), (21, 2)]);
        expect(requests, isEmpty);
        expect(result.removed, 2);
      },
    );

    test('mixed subscription keeps valid content and hides only invalid media when enabled', () async {
      pages[(1, 1)] = contents([
        (id: 101, type: 2, valid: false),
        (id: 102, type: 2, valid: true),
      ]);
      final result = await cleaner.run([subscription(1)], hideInvalid: true);
      expect(cancelled, isEmpty);
      expect(hidden[(21, 1)], {(101, 2)});
      expect(result.hidden, 1);
      expect(result.failed, 0);
    });

    test('disabled optional setting preserves mixed subscriptions without hiding media', () async {
      pages[(1, 1)] = contents([
        (id: 101, type: 2, valid: false),
        (id: 102, type: 2, valid: true),
      ], hasMore: true);
      final result = await cleaner.run([subscription(1)], hideInvalid: false);
      expect(cancelled, isEmpty);
      expect(hidden, isEmpty);
      expect(requests, [(1, 1)]);
      expect(result.failed, 0);
    });

    test('cancels only subscriptions whose every page is invalid', () async {
      pages[(1, 1)] = contents([
        (id: 101, type: 2, valid: false),
      ], hasMore: true);
      pages[(1, 2)] = contents([(id: 102, type: 2, valid: false)]);
      pages[(2, 1)] = contents([
        (id: 201, type: 2, valid: false),
      ], hasMore: true);
      pages[(2, 2)] = contents([(id: 202, type: 2, valid: true)]);
      final result = await cleaner.run([
        subscription(1),
        subscription(2),
      ], hideInvalid: false);
      expect(requests, [(1, 1), (1, 2), (2, 1), (2, 2)]);
      expect(cancelled, [(21, 1)]);
      expect(result.removed, 1);
    });

    test('an early final page with missing declared content cannot cancel a subscription', () async {
      pages[(1, 1)] = const Success(
        SubscriptionContentPage(
          items: [(id: 101, type: 2, valid: false)],
          hasMore: false,
          total: 2,
        ),
      );
      final result = await cleaner.run([subscription(1)], hideInvalid: true);
      expect(cancelled, isEmpty);
      expect(result.failed, 1);
    });

    test('unreadable or empty contents are preserved', () async {
      pages[(1, 1)] = contents([
        (id: 101, type: 2, valid: false),
      ], hasMore: true);
      pages[(1, 2)] = const Error('权限不足');
      pages[(2, 1)] = contents([]);
      final result = await cleaner.run([
        subscription(1),
        subscription(2),
      ], hideInvalid: true);
      expect(cancelled, isEmpty);
      expect(hidden, isEmpty);
      expect(result.failed, 1);
    });

    test('temporary video errors cannot classify the entire subscription as invalid', () async {
      pages[(1, 1)] = contents([
        (id: 101, type: 2, valid: false),
        (id: 102, type: 2, valid: null),
      ]);
      videoStates[102] = const Error('风控', code: -412);
      final result = await cleaner.run([subscription(1)], hideInvalid: true);
      expect(cancelled, isEmpty);
      expect(hidden, isEmpty);
      expect(result.failed, 1);
    });

    test('failed cancellation does not count as removed and other subscriptions continue', () async {
      cancelFails = true;
      final result = await cleaner.run([
        subscription(1, state: 1),
        subscription(2, state: 1),
      ], hideInvalid: false);
      expect(result.removed, 0);
      expect(result.failed, 2);
    });

    test(
      'unknown types are preserved and stale runs perform no changes',
      () async {
        final unknown = await cleaner.run([
          subscription(1, type: 99, state: 1),
        ], hideInvalid: true);
        expect(unknown.failed, 1);
        await cleaner.run(
          [subscription(2, state: 1)],
          hideInvalid: true,
          isCurrent: () => false,
        );
        expect(cancelled, isEmpty);
      },
    );

    test('repeated content pages stop without cancelling an incompletely scanned subscription', () async {
      pages[(1, 1)] = contents([
        (id: 101, type: 2, valid: false),
      ], hasMore: true);
      pages[(1, 2)] = pages[(1, 1)]!;
      final result = await cleaner.run([subscription(1)], hideInvalid: true);
      expect(cancelled, isEmpty);
      expect(requests.length, 2);
      expect(result.failed, 1);
    });
  });
  test(
    'loads every subscription page before returning a cleanup snapshot',
    () async {
      final requests = <int>[];
      final result = await loadSubscriptionSnapshot((page) async {
        requests.add(page);
        return Success(
          SubData(
            list: [SubItemModel(id: page, type: 21, state: page == 2 ? 1 : 0)],
            hasMore: page < 3,
          ),
        );
      });
      expect(requests, [1, 2, 3]);
      expect(result.data.map((item) => item.id), [1, 2, 3]);
    },
  );

  test(
    'deduplicates overlapping pages by both subscription type and id',
    () async {
      final result = await loadSubscriptionSnapshot(
        (page) async => Success(
          SubData(
            list: [
              SubItemModel(id: 1, type: 11),
              if (page == 2) SubItemModel(id: 1, type: 21),
            ],
            hasMore: page == 1,
          ),
        ),
      );
      expect(result.data.map((item) => (item.type, item.id)), [
        (11, 1),
        (21, 1),
      ]);
    },
  );

  test(
    'later page failure does not return a partial cleanup snapshot',
    () async {
      final result = await loadSubscriptionSnapshot(
        (page) async => page == 1
            ? Success(
                SubData(
                  list: [SubItemModel(id: 1, type: 21, state: 1)],
                  hasMore: true,
                ),
              )
            : const Error('网络错误'),
      );
      expect(result, const Error('网络错误'));
    },
  );

  test(
    'stops on repeated pages instead of looping through the same subscriptions',
    () async {
      var requests = 0;
      final result = await loadSubscriptionSnapshot((page) async {
        requests++;
        return Success(
          SubData(list: [SubItemModel(id: 1, type: 21)], hasMore: true),
        );
      });
      expect(requests, 2);
      expect(result, isA<Error>());
    },
  );

  test('accepts an empty final page and rejects unknown pagination', () async {
    final empty = await loadSubscriptionSnapshot(
      (_) async => Success(SubData(hasMore: false)),
    );
    expect(empty.data, isEmpty);
    final unknown = await loadSubscriptionSnapshot(
      (_) async => Success(SubData()),
    );
    expect(unknown, isA<Error>());
  });
}
