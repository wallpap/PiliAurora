import 'package:pili_aurora/http/validate.dart';
import 'package:pili_aurora/utils/request_utils.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/search_panel/controller.dart';
import 'package:pili_aurora/pages/search_panel/video/view.dart';
import 'package:pili_aurora/pages/search_result/view.dart';
import 'package:pili_aurora/models/common/search/search_type.dart';
import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _ResultsNotifier extends SearchResultsNotifier {
  _ResultsNotifier(super.query, this.queries);
  final List<SearchResultsQuery> queries;
  @override
  Future<SearchResultsState> build() async {
    queries.add(query);
    return SearchResultsState(items: [], nextPage: 2, hasMore: false, total: 3);
  }
}

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
  SearchResultsQuery query({
    SearchType type = SearchType.video,
    String keyword = 'test',
    Object? owner,
    String filters = '{}',
    Object? revision,
  }) => (
    keyword: keyword,
    type: type,
    owner: owner ?? type,
    filters: filters,
    revision: revision ?? type,
  );
  Map<String, dynamic> video(int id, {int mid = 200}) => {
    'aid': id,
    'bvid': 'BV$id',
    'title': 'video$id',
    'mid': mid,
    'author': 'user$mid',
    'duration': '1:00',
  };
  Map<String, dynamic> page(
    List<int> ids, {
    int total = 80,
    bool all = false,
  }) => {
    'code': 0,
    'data': {
      'numResults': total,
      'result': all
          ? [
              {
                'result_type': 'video',
                'data': [for (final id in ids) video(id)],
              },
              {
                'result_type': 'bili_user',
                'data': [
                  {'mid': 2, 'uname': 'two'},
                ],
              },
            ]
          : [for (final id in ids) video(id)],
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
    (GStorage.setting as MemoryBox).data.clear();
    GStorage.setting.put(SettingBoxKey.filterBlockedAuthors, false);
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

  test('分类、关键词、页面与筛选快照隔离，请求固定推荐账号', () async {
    final recommend = login('recommend');
    Accounts.accountMode[AccountType.recommend.index] = recommend;
    final queries = [
      query(),
      query(keyword: 'other'),
      query(owner: Object()),
      query(
        filters:
            '{"order":"click","duration":1,"tids":4,"pubBegin":1,"pubEnd":2}',
      ),
      query(type: SearchType.bili_user),
    ];
    for (final q in queries) {
      container.listen(searchResultsProvider(q), (_, _) {});
    }
    await dispatched(5);
    for (final request in requests) {
      expect(request.options.extra['account'], same(recommend));
      if (request.options.queryParameters['order'] == 'click') {
        expect(request.options.queryParameters['duration'], 1);
        expect(request.options.queryParameters['tids'], 4);
        expect(request.options.queryParameters['pubtime_begin_s'], 1);
      }
      request.reply.complete(
        request.options.queryParameters['search_type'] == 'bili_user'
            ? {
                'code': 0,
                'data': {
                  'numResults': 1,
                  'result': [
                    {'mid': 5, 'uname': 'five'},
                  ],
                },
              }
            : page([1], total: 1),
      );
    }
    for (final q in queries) {
      await container.read(searchResultsProvider(q).future);
    }
    expect(
      container
          .read(searchResultsProvider(queries.last))
          .requireValue
          .items
          .single
          .mid,
      5,
    );
    expect(
      () => container
          .read(searchResultsProvider(queries.first))
          .requireValue
          .items
          .clear(),
      throwsUnsupportedError,
    );
  });

  test('综合首屏保留卡片，后续页请求视频；分页串行失败重试与去重', () async {
    final q = query(type: SearchType.all);
    final provider = searchResultsProvider(q);
    container.listen(provider, (_, _) {});
    await dispatched(1);
    expect(requests.single.options.path, Api.searchAll);
    requests.single.reply.complete(page(range(1, 20), all: true));
    final first = await container.read(provider.future);
    expect(first.users.single.mid, 2);
    final notifier = container.read(provider.notifier);
    final more = notifier.loadMore();
    await notifier.loadMore();
    await dispatched(2);
    expect(requests.last.options.path, Api.searchByType);
    expect(requests.last.options.queryParameters['search_type'], 'video');
    expect(requests.last.options.queryParameters['page'], 2);
    requests.last.reply.complete({'code': -1, 'message': 'failed'});
    await more;
    expect(container.read(provider).requireValue.nextPage, 2);
    expect(container.read(provider).requireValue.users.single.mid, 2);
    await notifier.loadMore();
    expect(requests, hasLength(2));
    final retry = notifier.loadMore(retry: true);
    await dispatched(3);
    requests.last.reply.complete(page(range(20, 20)));
    await retry;
    expect(container.read(provider).requireValue.items, hasLength(39));
    expect(first.items, hasLength(20));
    final duplicate = notifier.loadMore();
    await dispatched(4);
    requests.last.reply.complete(page(range(20, 20)));
    await duplicate;
    expect(container.read(provider).requireValue.hasMore, isFalse);
  });

  test('综合筛选直接查询视频，分页期间移除项不被迟到结果恢复', () async {
    final q = query(
      type: SearchType.all,
      filters: '{"order":"click","filtered":true}',
    );
    final provider = searchResultsProvider(q);
    container.listen(provider, (_, _) {});
    await dispatched(1);
    expect(requests.single.options.path, Api.searchByType);
    requests.single.reply.complete(page(range(1, 20)));
    await container.read(provider.future);
    final notifier = container.read(provider.notifier);
    final more = notifier.loadMore();
    await dispatched(2);
    notifier.remove(container.read(provider).requireValue.items.first);
    requests.last.reply.complete(page(range(20, 20)));
    await more;
    expect(
      container
          .read(provider)
          .requireValue
          .items
          .any((dynamic e) => e.aid == 1),
      isFalse,
    );
  });

  test('分页失败和重试保留请求期间移除的卡片', () async {
    final provider = searchResultsProvider(query());
    container.listen(provider, (_, _) {});
    await dispatched(1);
    requests.single.reply.complete(page(range(1, 20)));
    await container.read(provider.future);
    final notifier = container.read(provider.notifier);
    final more = notifier.loadMore();
    await dispatched(2);
    notifier.remove(container.read(provider).requireValue.items.first);
    requests.last.reply.complete({'code': -1, 'message': 'failed'});
    await more;
    final failed = container.read(provider).requireValue;
    expect(failed.items, hasLength(19));
    expect(failed.items.any((dynamic e) => e.aid == 1), isFalse);
    expect(failed.nextPage, 2);
    expect(failed.loadingMore, isFalse);
    expect(failed.error, isNotNull);
    final retry = notifier.loadMore(retry: true);
    await dispatched(3);
    requests.last.reply.complete(page(range(20, 20)));
    await retry;
    expect(
      container
          .read(provider)
          .requireValue
          .items
          .any((dynamic e) => e.aid == 1),
      isFalse,
    );
  });

  test('同 UID 新凭据切换和刷新丢弃旧分页，错误态保留值禁止分页', () async {
    final q = query();
    final provider = searchResultsProvider(q);
    container.listen(provider, (_, _) {});
    await dispatched(1);
    requests.single.reply.complete(page(range(1, 20)));
    await container.read(provider.future);
    final notifier = container.read(provider.notifier);
    final more = notifier.loadMore();
    await dispatched(2);
    Accounts.accountMode[AccountType.recommend.index] = login('new');
    await Accounts.refresh();
    await container.pump();
    await dispatched(3);
    requests.last.reply.complete(page([99], total: 1));
    await container.read(provider.future);
    requests[1].reply.complete(page(range(21, 20)));
    await more;
    expect(container.read(provider).requireValue.items.single.aid, 99);
    container.invalidate(provider);
    await container.pump();
    await dispatched(4);
    requests.last.reply.complete({'code': -1, 'message': 'failed'});
    await expectLater(container.read(provider.future), throwsA(anything));
    await notifier.loadMore();
    expect(requests, hasLength(4));
  });

  test('验证重查固定原页和筛选，重复提交与过期验证失效', () async {
    final q = query(filters: '{"order":"click"}');
    final provider = searchResultsProvider(q);
    container.listen(provider, (_, _) {});
    await dispatched(1);
    requests.single.reply.complete({
      'code': 0,
      'data': {'v_voucher': 'voucher'},
    });
    await expectLater(
      container.read(provider.future),
      throwsA(isA<SearchVerificationRequired>()),
    );
    final challenge =
        container.read(provider).error! as SearchVerificationRequired;
    final notifier = container.read(provider.notifier);
    final verify = notifier.verify(challenge, 'verified');
    await notifier.verify(challenge, 'duplicate');
    await dispatched(2);
    expect(requests.last.options.queryParameters['page'], 1);
    expect(requests.last.options.queryParameters['order'], 'click');
    expect(requests.last.options.queryParameters['gaia_vtoken'], 'verified');
    requests.last.reply.complete(page([1], total: 1));
    await verify;
    await notifier.verify(challenge, 'stale');
    expect(requests, hasLength(2));
    container.invalidate(provider);
    await container.pump();
    await dispatched(3);
    requests.last.reply.complete(page([2], total: 1));
    await container.read(provider.future);
    await notifier.verify(challenge, 'stale');
    expect(requests, hasLength(3));
  });

  test('验证注册绑定发起账号，页面失效后不再打开验证或回调', () async {
    var current = true;
    var callbacks = 0;
    final registration = RequestUtils.validate(
      'voucher',
      (_) => callbacks++,
      account: account,
      isCurrent: () => current,
    );
    await dispatched(1);
    expect(requests.single.options.path, Api.gaiaVgateRegister);
    expect(requests.single.options.extra['account'], same(account));
    expect(requests.single.options.extra['noRetry'], isTrue);
    expect(requests.single.options.queryParameters['csrf'], 'old');
    current = false;
    requests.single.reply.complete({
      'code': 0,
      'data': {
        'geetest': {'gt': 'gt', 'challenge': 'challenge'},
        'token': 'fixture',
      },
    });
    await registration;
    expect(callbacks, 0);
    expect(requests, hasLength(1));
  });

  test('验证提交使用原账号 CSRF 与 HTTP 上下文且不自动重试', () async {
    final submit = ValidateHttp.gaiaVgateValidate(
      account: account,
      challenge: 'challenge',
      seccode: 'fixture',
      token: 'fixture',
      validate: 'fixture',
    );
    Accounts.accountMode[AccountType.main.index] = login('new');
    await dispatched(1);
    expect(requests.single.options.path, Api.gaiaVgateValidate);
    expect(requests.single.options.extra['account'], same(account));
    expect(requests.single.options.queryParameters['csrf'], 'old');
    expect(requests.single.options.extra['noRetry'], isTrue);
    requests.single.reply.complete({
      'code': 0,
      'data': {'is_valid': 1, 'grisk_id': 'fixture'},
    });
    expect((await submit).isSuccess, isTrue);
  });

  test('屏蔽过滤沿原始页补足，连续五页无增长停止', () async {
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    GStorage.setting.put(SettingBoxKey.filterBlockedAuthors, true);
    GlobalData().blackMids = {200};
    final q = query();
    final provider = searchResultsProvider(q);
    container.listen(provider, (_, _) {});
    for (var i = 0; i < 5; i++) {
      await dispatched(i + 1);
      requests[i].reply.complete(page(range(i * 20 + 1, 20), total: 500));
    }
    final data = await container.read(provider.future);
    expect(data.items, isEmpty);
    expect(data.nextPage, 6);
    expect(data.hasMore, isFalse);
  });

  test('主账号改变时重算过滤且隔离旧响应，推荐账号保持不变', () async {
    final q = query();
    final provider = searchResultsProvider(q);
    container.listen(provider, (_, _) {});
    await dispatched(1);
    Accounts.accountMode[AccountType.main.index] = login('main-new');
    await Accounts.refresh();
    await container.pump();
    await dispatched(2);
    expect(requests.last.options.extra['account'], same(account));
    requests.last.reply.complete(page([2], total: 1));
    await container.read(provider.future);
    requests.first.reply.complete(page([1], total: 1));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(provider).requireValue.items.single.aid, 2);
  });

  test('过滤空页沿新页码补足，综合卡片保留首屏快照', () async {
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    GStorage.setting.put(SettingBoxKey.filterBlockedAuthors, true);
    GlobalData().blackMids = {200};
    final q = query(type: SearchType.all);
    final provider = searchResultsProvider(q);
    container.listen(provider, (_, _) {});
    await dispatched(1);
    requests.single.reply.complete(page(range(1, 20), all: true));
    await dispatched(2);
    expect(requests.last.options.queryParameters['page'], 2);
    expect(requests.last.options.queryParameters['search_type'], 'video');
    requests.last.reply.complete({
      'code': 0,
      'data': {
        'numResults': 80,
        'result': [for (final id in range(21, 20)) video(id, mid: 300)],
      },
    });
    final data = await container.read(provider.future);
    expect(data.items, hasLength(20));
    expect(data.items.first.aid, 21);
    expect(data.users.single.mid, 2);
    expect(data.nextPage, 3);
  });

  test('释放挂起的查询后不再发补页或响应验证', () async {
    final q = query();
    final provider = searchResultsProvider(q);
    final sub = container.listen(provider, (_, _) {});
    await dispatched(1);
    sub.close();
    await container.pump();
    requests.single.reply.complete(page([1]));
    await Future<void>.delayed(Duration.zero);
    expect(requests, hasLength(1));
  });

  testWidgets('视频筛选建立新查询，分类计数从有效快照回传', (tester) async {
    container.dispose();
    final queries = <SearchResultsQuery>[];
    container = ProviderContainer(
      overrides: [
        searchResultsProvider.overrideWith2(
          (query) => _ResultsNotifier(query, queries),
        ),
      ],
    );
    final counts = <int?>[];
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: SearchVideoPanel(
            keyword: 'test',
            searchType: SearchType.video,
            tag: Object(),
            onCount: counts.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(queries, hasLength(1));
    expect(counts.last, 3);
    await tester.tap(find.text('播放多'));
    await tester.pumpAndSettle();
    expect(queries, hasLength(2));
    expect(queries.last.filters, contains('click'));
    expect(queries.last.revision, isNot(same(queries.first.revision)));
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump();
    expect(requests, isEmpty);
  });

  testWidgets('搜索结果页通过回调回传分类且不注册 GetX 状态', (tester) async {
    container.dispose();
    final queries = <SearchResultsQuery>[];
    container = ProviderContainer(
      overrides: [
        searchResultsProvider.overrideWith2(
          (query) => _ResultsNotifier(query, queries),
        ),
      ],
    );
    final selected = <int>[];
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: GetMaterialApp(
          getPages: [
            GetPage(name: '/results', page: () => const SearchResultPage()),
          ],
          home: Builder(
            builder: (_) => TextButton(
              onPressed: () => Get.toNamed<void>(
                '/results',
                parameters: {'keyword': 'test'},
                arguments: {'fromSearch': true, 'onIndexChanged': selected.add},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, '视频'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expect(selected, contains(SearchType.video.index));
    expect(queries.any((q) => q.type == SearchType.video), isTrue);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump();
  });
}
