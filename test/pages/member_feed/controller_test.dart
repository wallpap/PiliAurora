import 'package:pili_aurora/pages/member_upower_rank/controller.dart';
import 'package:pili_aurora/models/common/member/contribute_type.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/common/member_feed.dart';
import 'package:pili_aurora/pages/article_list/controller.dart';
import 'package:pili_aurora/pages/pgc_index/controller.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  final dispatched = interceptor.waitForRequests;
  late ProviderContainer container;
  late LoginAccount account;
  LoginAccount login(String csrf) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '100', 'bili_jct': csrf}),
    null,
    null,
  )..activated = true;
  MemberFeedQuery query(
    MemberFeedKind kind, {
    Object? owner,
    String mid = '200',
  }) => (kind: kind, mid: mid, owner: owner ?? kind);
  Map<String, dynamic> page(
    MemberFeedKind kind,
    List<int> ids, {
    int total = 45,
    bool more = true,
  }) => {
    'code': 0,
    'data': switch (kind) {
      MemberFeedKind.article => {
        'count': total,
        'item': [
          for (final id in ids) {'uri': 'article/$id', 'title': 'article$id'},
        ],
      },
      MemberFeedKind.audio => {
        'totalSize': total,
        'data': [
          for (final id in ids) {'id': id, 'uid': 200, 'title': 'audio$id'},
        ],
      },
      MemberFeedKind.coin || MemberFeedKind.like => {
        'count': total,
        'item': [
          for (final id in ids)
            {'param': '$id', 'uri': 'video/$id', 'title': 'video$id'},
        ],
      },
      MemberFeedKind.cheese => {
        'items': [
          for (final id in ids) {'season_id': id, 'title': 'course$id'},
        ],
        'page': {'next': more},
      },
      MemberFeedKind.comic => {
        'item': [
          for (final id in ids)
            {'param': '$id', 'uri': 'comic/$id', 'title': 'comic$id'},
        ],
        'count': total,
        'has_next': more,
      },
      MemberFeedKind.series => {
        'items_lists': {
          'seasons_list': [
            for (final id in ids)
              {
                'meta': {'season_id': id, 'name': 'series$id'},
              },
          ],
          'series_list': [],
          'page': {'total': total},
        },
      },
      MemberFeedKind.shop => {
        'data': [
          for (final id in ids) {'cardUrl': 'shop/$id', 'title': 'shop$id'},
        ],
        'showMoreTab': true,
        'clickUrl': 'https://example.com/?url=shop',
        'showMoreDesc': 'more',
      },
      MemberFeedKind.guard => {
        'guard_top_list': [
          for (final id in ids)
            {'uid': id, 'username': 'guard$id', 'face': '', 'guard_level': 1},
        ],
        'has_more': more ? 1 : 0,
      },
    },
  };
  List<int> range(int start, int count) =>
      List.generate(count, (index) => start + index);
  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
    Accounts.account = MemoryBox<LoginAccount>();
    AnonymousAccount().activated = true;
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(
        interceptor,
      );
  });
  setUp(() {
    requests.clear();
    GStorage.localCache.put(
      LocalCacheKey.mixinKey,
      '01234567890123456789012345678901',
    );
    GStorage.localCache.put(
      LocalCacheKey.timeStamp,
      DateTime.now().millisecondsSinceEpoch,
    );
    account = login('old');
    Accounts.accountMode[AccountType.main.index] = account;
    Accounts.accountMode[AccountType.recommend.index] = account;
    container = ProviderContainer();
  });
  tearDown(() {
    container.dispose();
    for (final request in requests) {
      if (!request.reply.isCompleted) {
        request.reply.complete({'code': -1, 'message': 'closed'});
      }
    }
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    Get.reset();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  test('九类列表固定账号、目标与入口，列表快照不可变', () async {
    final subscriptions = [
      for (final kind in MemberFeedKind.values)
        container.listen(memberFeedProvider(query(kind)), (_, _) {}),
    ];
    await dispatched(9);
    final paths = {
      Api.spaceArticle: MemberFeedKind.article,
      Api.spaceAudio: MemberFeedKind.audio,
      Api.coinArc: MemberFeedKind.coin,
      Api.likeArc: MemberFeedKind.like,
      Api.spaceShop: MemberFeedKind.shop,
      Api.memberGuard: MemberFeedKind.guard,
      Api.spaceCheese: MemberFeedKind.cheese,
      ContributeType.comic.api: MemberFeedKind.comic,
      Api.seasonSeries: MemberFeedKind.series,
    };
    for (final request in requests) {
      expect(request.options.extra['account'], same(account));
      final kind = paths[request.options.path]!;
      request.reply.complete(page(kind, [1, 2, 3, 4], total: 4, more: false));
    }
    for (final kind in MemberFeedKind.values) {
      final data = await container.read(memberFeedProvider(query(kind)).future);
      expect(data.items, hasLength(kind == MemberFeedKind.guard ? 1 : 4));
      expect(data.hasMore, isFalse);
      expect(data.items.clear, throwsUnsupportedError);
      if (kind == MemberFeedKind.guard) {
        expect(data.tops.map((e) => e.uid), [1, 2, 3]);
      }
      if (kind == MemberFeedKind.shop) expect(data.shop?.showMoreDesc, 'more');
    }
    for (final sub in subscriptions) {
      sub.close();
    }
  });

  test('分页互斥、失败保留页码，显式重试去重，重复页停止', () async {
    final q = query(MemberFeedKind.coin);
    final provider = memberFeedProvider(q);
    container.listen(provider, (_, _) {});
    await dispatched(1);
    requests.single.reply.complete(page(q.kind, range(1, 20)));
    await container.read(provider.future);
    final notifier = container.read(provider.notifier);
    final more = notifier.loadMore();
    await notifier.loadMore();
    await dispatched(2);
    requests.last.reply.complete({'code': -1, 'message': 'failed'});
    await more;
    expect(container.read(provider).requireValue.nextPage, 2);
    expect(container.read(provider).requireValue.items, hasLength(20));
    await notifier.loadMore();
    expect(requests, hasLength(2));
    final retry = notifier.loadMore(retry: true);
    await dispatched(3);
    expect(requests.last.options.queryParameters['pn'], 2);
    requests.last.reply.complete(page(q.kind, range(20, 20)));
    await retry;
    expect(container.read(provider).requireValue.items, hasLength(39));
    final duplicate = notifier.loadMore();
    await dispatched(4);
    requests.last.reply.complete(page(q.kind, range(20, 20), total: 100));
    await duplicate;
    expect(container.read(provider).requireValue.hasMore, isFalse);
  });

  test('舰队前三名不改变响应，分页按 UID 去重且保留排名', () async {
    final q = query(MemberFeedKind.guard);
    final provider = memberFeedProvider(q);
    container.listen(provider, (_, _) {});
    await dispatched(1);
    requests.single.reply.complete(page(q.kind, range(1, 5)));
    final before = await container.read(provider.future);
    expect(before.tops.map((e) => e.uid), [1, 2, 3]);
    expect(before.items.map((dynamic e) => e.uid), [4, 5]);
    final more = container.read(provider.notifier).loadMore();
    await dispatched(2);
    expect(requests.last.options.queryParameters['page'], 2);
    requests.last.reply.complete(page(q.kind, [3, 5, 6], more: false));
    await more;
    expect(
      container.read(provider).requireValue.items.map((dynamic e) => e.uid),
      [4, 5, 6],
    );
    expect(before.items.map((dynamic e) => e.uid), [4, 5]);
  });

  test('页面实例隔离，切号刷新与释放丢弃迟到分页', () async {
    final q = query(MemberFeedKind.audio);
    final provider = memberFeedProvider(q);
    final sub = container.listen(provider, (_, _) {});
    await dispatched(1);
    requests.single.reply.complete(page(q.kind, range(1, 20)));
    await container.read(provider.future);
    final old = container.read(provider.notifier).loadMore();
    await dispatched(2);
    Accounts.accountMode[AccountType.main.index] = login('new');
    await Accounts.refresh();
    await container.pump();
    await dispatched(3);
    requests.last.reply.complete(page(q.kind, [99], total: 1));
    await container.read(provider.future);
    requests[1].reply.complete(page(q.kind, range(21, 20)));
    await old;
    expect(container.read(provider).requireValue.items.single.id, 99);
    final other = query(MemberFeedKind.audio, owner: Object());
    final second = container.listen(memberFeedProvider(other), (_, _) {});
    await dispatched(4);
    expect(container.read(memberFeedProvider(other)).isLoading, isTrue);
    sub.close();
    second.close();
    await container.pump();
    requests.last.reply.complete(page(q.kind, [1]));
  });

  test('文集元数据和文章同一快照，账号变化废弃旧查询', () async {
    final provider = articleCollectionProvider('10');
    container.listen(provider, (_, _) {});
    await dispatched(1);
    expect(requests.single.options.queryParameters['id'], '10');
    expect(requests.single.options.extra['account'], same(account));
    Accounts.accountMode[AccountType.main.index] = login('new');
    await Accounts.refresh();
    await container.pump();
    await dispatched(2);
    Map<String, dynamic> collection(String name) => {
      'code': 0,
      'data': {
        'list': {'id': 10, 'name': name},
        'articles': [],
        'author': {'mid': 200, 'name': name},
      },
    };
    requests.last.reply.complete(collection('new'));
    await container.read(provider.future);
    requests.first.reply.complete(collection('old'));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(provider).requireValue.list?.name, 'new');
    expect(
      () => container.read(provider).requireValue.articles.clear(),
      throwsUnsupportedError,
    );
  });

  test('充电排行按等级、目标与页面隔离，账号变化不接收旧排行', () async {
    final owner = Object();
    final all = (mid: '200', privilege: null as int?, owner: owner);
    final level = (mid: '200', privilege: 1 as int?, owner: owner);
    container
      ..listen(upowerRankingProvider(all), (_, _) {})
      ..listen(upowerRankingProvider(level), (_, _) {});
    await dispatched(2);
    for (final request in requests) {
      expect(request.options.path, Api.upowerRank);
      expect(request.options.extra['account'], same(account));
      expect(request.options.queryParameters['csrf'], 'old');
      expect(request.options.queryParameters['up_mid'], '200');
      request.reply.complete({
        'code': 0,
        'data': {
          'rank_info': [
            {
              'mid': request.options.queryParameters['privilege_type'] == null
                  ? 1
                  : 2,
              'nickname': 'rank',
              'day': 3,
            },
          ],
          'level_info': [
            {'privilege_type': 0, 'name': 'all'},
            {'privilege_type': 1, 'name': 'one'},
          ],
        },
      });
    }
    final before = await container.read(upowerRankingProvider(all).future);
    final filtered = await container.read(upowerRankingProvider(level).future);
    expect(before.ranks.single.mid, 1);
    expect(filtered.ranks.single.mid, 2);
    expect(before.levels, hasLength(2));
    expect(before.ranks.clear, throwsUnsupportedError);
    container.invalidate(upowerRankingProvider(all));
    await container.pump();
    await dispatched(3);
    Accounts.accountMode[AccountType.main.index] = login('new');
    await Accounts.refresh();
    await container.pump();
    await dispatched(5);
    for (final request in requests.skip(3)) {
      request.reply.complete({
        'code': 0,
        'data': {'rank_info': [], 'level_info': []},
      });
    }
    await container.read(upowerRankingProvider(all).future);
    requests[2].reply.complete({
      'code': 0,
      'data': {
        'rank_info': [
          {'mid': 9},
        ],
        'level_info': [],
      },
    });
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(upowerRankingProvider(all)).requireValue.ranks,
      isEmpty,
    );
  });

  test('PGC 首页和分页跟随推荐账号，切号丢弃旧分页', () async {
    final recommended = login('recommend');
    Accounts.accountMode[AccountType.recommend.index] = recommended;
    final provider = pgcResultsProvider((
      indexType: null,
      filters: '{}',
      owner: Object(),
    ));
    container.listen(provider, (_, _) {});
    await dispatched(1);
    expect(requests.single.options.extra['account'], same(recommended));
    Map<String, dynamic> results(int id) => {
      'code': 0,
      'data': {
        'list': [
          {'season_id': id},
        ],
        'has_next': 1,
      },
    };
    requests.single.reply.complete(results(1));
    await container.read(provider.future);
    final more = container.read(provider.notifier).loadMore();
    await dispatched(2);
    expect(requests.last.options.extra['account'], same(recommended));
    final next = login('next');
    Accounts.accountMode[AccountType.recommend.index] = next;
    await Accounts.refresh();
    await container.pump();
    await dispatched(3);
    expect(requests.last.options.extra['account'], same(next));
    expect(requests.last.options.queryParameters['page'], 1);
    requests.last.reply.complete(results(99));
    await container.read(provider.future);
    requests[1].reply.complete(results(2));
    await more;
    expect(container.read(provider).requireValue.items.single.seasonId, 99);
  });

  test('PGC 条件与筛选查询隔离，分页失败重试保持筛选及账号', () async {
    container.listen(pgcConditionsProvider(null), (_, _) {});
    await dispatched(1);
    expect(requests.single.options.path, Api.pgcIndexCondition);
    requests.single.reply.complete({
      'code': 0,
      'data': {
        'order': [
          {'name': '默认', 'field': '3'},
        ],
        'filter': [],
      },
    });
    await container.read(pgcConditionsProvider(null).future);
    final q = (
      indexType: null as int?,
      filters: '{"order":"3"}',
      owner: Object(),
    );
    final provider = pgcResultsProvider(q);
    container.listen(provider, (_, _) {});
    await dispatched(2);
    Map<String, dynamic> results(List<int> ids, bool more) => {
      'code': 0,
      'data': {
        'list': [
          for (final id in ids) {'season_id': id, 'title': 's$id'},
        ],
        'has_next': more ? 1 : 0,
      },
    };
    requests.last.reply.complete(results([1], true));
    await container.read(provider.future);
    final more = container.read(provider.notifier).loadMore();
    await dispatched(3);
    expect(requests.last.options.queryParameters['order'], '3');
    expect(requests.last.options.queryParameters['page'], 2);
    expect(requests.last.options.extra['account'], same(account));
    requests.last.reply.complete({'code': -1, 'message': 'failed'});
    await more;
    final retry = container.read(provider.notifier).loadMore(retry: true);
    await dispatched(4);
    expect(requests.last.options.queryParameters['page'], 2);
    requests.last.reply.complete(results([1, 2], false));
    await retry;
    expect(container.read(provider).requireValue.items.map((e) => e.seasonId), [
      1,
      2,
    ]);
    final changed = (
      indexType: null as int?,
      filters: '{"order":"4"}',
      owner: q.owner,
    );
    container.listen(pgcResultsProvider(changed), (_, _) {});
    await dispatched(5);
    expect(requests.last.options.queryParameters['order'], '4');
    expect(container.read(pgcResultsProvider(changed)).isLoading, isTrue);
  });
}
