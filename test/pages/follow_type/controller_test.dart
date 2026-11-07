import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/models/remote/follow/list.dart';
import 'package:pili_aurora/pages/follow_type/view.dart';
import 'package:pili_aurora/pages/share/view.dart' show UserModel;
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/follow_type/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

class _Box<T> implements Box<T> {
  final valuesMap = <dynamic, T>{};
  @override
  T? get(dynamic key, {T? defaultValue}) => valuesMap[key] ?? defaultValue;
  @override
  Future<void> put(dynamic key, T value) async {
    valuesMap[key] = value;
  }

  @override
  Iterable<T> get values => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef _Pending = ({
  RequestOptions options,
  Completer<Map<String, dynamic>> reply,
});

class _FixtureNotifier extends FollowQueryNotifier {
  _FixtureNotifier(super.query);
  @override
  Future<FollowQueryState> build() async => FollowQueryState(
    source: Object(),
    items: [FollowItemModel(mid: 42, uname: '选择用户', face: '')],
    total: 1,
    nextPage: 2,
    hasMore: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final requests = <_Pending>[];
  late ProviderContainer container;
  late LoginAccount account;
  const fans = (kind: FollowKind.fans, mid: null, newFans: false);
  const recent = (kind: FollowKind.fans, mid: null, newFans: true);
  LoginAccount login(int mid, String csrf) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': csrf}),
    null,
    null,
  )..activated = true;
  List<int> range(int start, int count) =>
      List.generate(count, (i) => start + i);
  Map<String, dynamic> page(
    List<int> ids, {
    int? total = 45,
    int attribute = 0,
  }) => {
    'code': 0,
    'data': {
      'list': [
        for (final id in ids)
          {'mid': id, 'uname': 'user-$id', 'face': '', 'attribute': attribute},
      ],
      'total': ?total,
    },
  };
  Future<void> dispatched(int count) async {
    for (var i = 0; i < 100 && requests.length < count; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(requests, hasLength(count));
  }

  Future<void> select(LoginAccount next) async {
    Accounts.accountMode[AccountType.main.index] = next;
    await Accounts.refresh();
    await container.pump();
  }

  FollowQueryState current(FollowQuery query) =>
      container.read(followQueryProvider(query)).requireValue;
  Future<void> load(
    FollowQuery query, {
    List<int>? ids,
    int? total = 45,
  }) async {
    await dispatched(1);
    requests[0].reply.complete(page(ids ?? range(1, 20), total: total));
    await container.read(followQueryProvider(query).future);
  }

  setUpAll(() {
    GStorage.setting = _Box<dynamic>();
    GStorage.localCache = _Box<dynamic>();
    Accounts.account = _Box<LoginAccount>();
    AnonymousAccount().activated = true;
    Request();
    Request.dio.interceptors.clear();
    Request.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final reply = Completer<Map<String, dynamic>>();
          requests.add((options: options, reply: reply));
          handler.resolve(
            Response(requestOptions: options, data: await reply.future),
          );
        },
      ),
    );
  });
  setUp(() {
    requests.clear();
    account = login(100, 'old');
    Accounts.accountMode[AccountType.main.index] = account;
    container = ProviderContainer();
  });
  tearDown(() {
    container.dispose();
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    for (final request in requests) {
      if (!request.reply.isCompleted) {
        request.reply.complete({'code': -1, 'message': 'closed'});
      }
    }
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('类型、目标和新粉丝查询隔离，请求与名称绑定账号', () async {
    const sameQuery = (kind: FollowKind.same, mid: 12, newFans: false);
    const followed = (kind: FollowKind.followed, mid: 12, newFans: false);
    const other = (kind: FollowKind.same, mid: 13, newFans: false);
    final subs = [
      for (final query in [fans, recent, sameQuery, followed, other])
        container.listen(followQueryProvider(query), (_, _) {}),
    ];
    final nameSub = container.listen(followNameProvider(12), (_, _) {});
    await dispatched(6);
    expect(requests.map((r) => r.options.path), [
      Api.fans,
      Api.fans,
      Api.sameFollowing,
      Api.followedUp,
      Api.sameFollowing,
      Api.memberCardInfo,
    ]);
    for (final request in requests) {
      expect(request.options.extra['account'], same(account));
    }
    expect(requests[0].options.queryParameters['order_type'], 'attention');
    expect(requests[1].options.queryParameters['order_type'], isNull);
    expect(requests[2].options.queryParameters['vmid'], 12);
    expect(requests[2].options.queryParameters['csrf'], 'old');
    expect(requests[3].options.queryParameters['csrf'], 'old');
    expect(requests[4].options.queryParameters['vmid'], 13);
    for (var i = 0; i < 5; i++) {
      requests[i].reply.complete(page([i + 1], total: 1));
    }
    requests[5].reply.complete({
      'code': 0,
      'data': {
        'card': {'name': 'target'},
      },
    });
    expect(await container.read(followNameProvider(12).future), 'target');
    for (var i = 0; i < 5; i++) {
      expect(
        (await container.read(
          followQueryProvider([fans, recent, sameQuery, followed, other][i])
              .future,
        )).items.single.mid,
        i + 1,
      );
    }
    for (final sub in subs) {
      sub.close();
    }
    nameSub.close();
  });

  test('分页失败保留内容并显式重试，刷新丢弃旧分页', () async {
    final sub = container.listen(followQueryProvider(fans), (_, _) {});
    await load(fans);
    final notifier = container.read(followQueryProvider(fans).notifier);
    final failed = notifier.loadMore();
    await dispatched(2);
    requests[1].reply.complete({'code': -1, 'message': 'failed'});
    await failed;
    expect(current(fans).pageError, isNotNull);
    expect(current(fans).items.length, 20);
    final retry = notifier.loadMore(retry: true);
    await dispatched(3);
    expect(requests[2].options.queryParameters['pn'], 2);
    requests[2].reply.complete(page(range(21, 20)));
    await retry;
    expect(current(fans).items.length, 40);
    final late = notifier.loadMore();
    await dispatched(4);
    container.invalidate(followQueryProvider(fans));
    await container.pump();
    await dispatched(5);
    requests[4].reply.complete(page([90], total: 1));
    await container.read(followQueryProvider(fans).future);
    requests[3].reply.complete(page([41, 42, 43, 44, 45]));
    await late;
    expect(current(fans).items.single.mid, 90);
    sub.close();
  });

  test('同 mid 新凭据与切号使旧查询和写入失效', () async {
    final sub = container.listen(followQueryProvider(recent), (_, _) {});
    await load(recent, ids: [1], total: 1);
    final write = container
        .read(followQueryProvider(recent).notifier)
        .followBack(1);
    await dispatched(2);
    expect(requests[1].options.extra['account'], same(account));
    expect(requests[1].options.extra['noRetry'], true);
    final replacement = login(100, 'new');
    Accounts.replaceCredentials(replacement);
    await container.pump();
    await dispatched(3);
    expect(requests[2].options.extra['account'], same(replacement));
    requests[2].reply.complete(page([2], total: 1));
    await container.read(followQueryProvider(recent).future);
    requests[1].reply.complete({'code': 0});
    expect(await write, isA<Error>());
    expect(current(recent).items.single.mid, 2);
    await select(login(200, 'other'));
    await dispatched(4);
    requests[3].reply.complete(page([3], total: 1));
    await container.read(followQueryProvider(recent).future);
    expect(current(recent).items.single.mid, 3);
    sub.close();
  });

  test('回关、取消关注和失败恢复，跨查询同 UID 写入互斥', () async {
    final a = container.listen(followQueryProvider(recent), (_, _) {});
    final b = container.listen(followQueryProvider(fans), (_, _) {});
    await dispatched(2);
    requests[0].reply.complete(page([1], total: 1));
    requests[1].reply.complete(page([1], total: 1));
    await container.read(followQueryProvider(recent).future);
    await container.read(followQueryProvider(fans).future);
    final first = container.read(followQueryProvider(recent).notifier);
    final other = container.read(followQueryProvider(fans).notifier);
    final write = first.followBack(1);
    await dispatched(3);
    expect((requests[2].options.data as Map)['act'], 1);
    expect(await other.remove(1), isA<Error>());
    expect(requests, hasLength(3));
    requests[2].reply.complete({'code': -1, 'message': 'failed'});
    expect(await write, isA<Error>());
    expect(current(recent).items.single.attribute, 0);
    b.close();
    await container.pump();
    final ok = first.followBack(1);
    await dispatched(4);
    requests[3].reply.complete({'code': 0});
    expect(await ok, isA<Success>());
    expect(current(recent).items.single.attribute, 6);
    final cancel = first.followBack(1);
    await dispatched(5);
    expect((requests[4].options.data as Map)['act'], 2);
    requests[4].reply.complete({'code': 0});
    await cancel;
    expect(current(recent).items.single.attribute, 0);
    a.close();
  });

  test('移除失败保留数据；成功重读页边界不跳过前移粉丝', () async {
    final sub = container.listen(followQueryProvider(fans), (_, _) {});
    await load(fans, total: 40);
    final notifier = container.read(followQueryProvider(fans).notifier);
    final failed = notifier.remove(1);
    await dispatched(2);
    requests[1].reply.complete({'code': -1, 'message': 'failed'});
    expect(await failed, isA<Error>());
    expect(current(fans).items.length, 20);
    final remove = notifier.remove(1);
    await dispatched(3);
    expect((requests[2].options.data as Map)['act'], 7);
    requests[2].reply.complete({'code': 0});
    await remove;
    expect(current(fans).nextPage, 1);
    final refill = notifier.loadMore();
    await dispatched(4);
    expect(requests[3].options.queryParameters['pn'], 1);
    requests[3].reply.complete(page(range(2, 20), total: 39));
    await refill;
    final next = notifier.loadMore();
    await dispatched(5);
    requests[4].reply.complete(page(range(22, 19), total: 39));
    await next;
    expect(current(fans).items.map((e) => e.mid), range(2, 39));
    expect(current(fans).hasMore, false);
    sub.close();
  });

  test('关闭页面后迟到写入不恢复 provider', () async {
    final provider = followQueryProvider(recent);
    final sub = container.listen(provider, (_, _) {});
    await load(recent, ids: [1], total: 1);
    final write = container.read(provider.notifier).followBack(1);
    await dispatched(2);
    sub.close();
    await container.pump();
    expect(container.exists(provider), false);
    requests[1].reply.complete({'code': 0});
    expect(await write, isA<Error>());
    expect(container.exists(provider), false);
  });

  test('名称查询在切换凭据后丢弃旧响应', () async {
    final provider = followNameProvider(9);
    final sub = container.listen(provider, (_, _) {});
    await dispatched(1);
    final replacement = login(100, 'replacement');
    Accounts.replaceCredentials(replacement);
    await container.pump();
    await dispatched(2);
    expect(requests[1].options.extra['account'], same(replacement));
    requests[1].reply.complete({
      'code': 0,
      'data': {
        'card': {'name': 'new'},
      },
    });
    expect(await container.read(provider.future), 'new');
    requests[0].reply.complete({
      'code': 0,
      'data': {
        'card': {'name': 'old'},
      },
    });
    await Future<void>.delayed(Duration.zero);
    expect(container.read(provider).value, 'new');
    sub.close();
  });

  test('刷新后旧写入不更新新列表且锁在响应后释放', () async {
    final provider = followQueryProvider(recent);
    final sub = container.listen(provider, (_, _) {});
    await load(recent, ids: [1], total: 1);
    final old = container.read(provider.notifier).followBack(1);
    await dispatched(2);
    container.invalidate(provider);
    await container.pump();
    await dispatched(3);
    requests[2].reply.complete(page([1], total: 1));
    await container.read(provider.future);
    expect(await container.read(provider.notifier).followBack(1), isA<Error>());
    expect(requests, hasLength(3));
    requests[1].reply.complete({'code': 0});
    expect(await old, isA<Error>());
    expect(current(recent).items.single.attribute, 0);
    final next = container.read(provider.notifier).followBack(1);
    await dispatched(4);
    requests[3].reply.complete({'code': 0});
    expect(await next, isA<Success>());
    sub.close();
  });

  test('切号后查询失败不允许用旧列表分页或写入', () async {
    final provider = followQueryProvider(fans);
    final sub = container.listen(provider, (_, _) {});
    await load(fans);
    await select(login(200, 'second'));
    await dispatched(2);
    final failure = expectLater(
      container.read(provider.future),
      throwsA(isA<Error>()),
    );
    requests[1].reply.complete({'code': -1, 'message': 'failed'});
    await failure;
    final notifier = container.read(provider.notifier);
    await notifier.loadMore();
    expect(await notifier.remove(1), isA<Error>());
    expect(requests, hasLength(2));
    sub.close();
  });

  testWidgets('共同关注和关注者列表保留标题', (tester) async {
    const sameQuery = (kind: FollowKind.same, mid: 12, newFans: false);
    const followedQuery = (kind: FollowKind.followed, mid: 12, newFans: false);
    container.dispose();
    container = ProviderContainer(
      overrides: [
        followQueryProvider(sameQuery)
            .overrideWith(() => _FixtureNotifier(sameQuery)),
        followQueryProvider(followedQuery)
            .overrideWith(() => _FixtureNotifier(followedQuery)),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: FollowTypePage(query: sameQuery, name: '目标'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('我与目标的共同关注'), findsOneWidget);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: FollowTypePage(query: followedQuery, name: '目标'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('我关注的1人也关注了目标'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('关系写入成功后同步其他粉丝列表，移除也刷新其他入口', () async {
    final a = container.listen(followQueryProvider(recent), (_, _) {});
    final b = container.listen(followQueryProvider(fans), (_, _) {});
    await dispatched(2);
    requests[0].reply.complete(page([1], total: 1));
    requests[1].reply.complete(page([1], total: 1));
    await container.read(followQueryProvider(recent).future);
    await container.read(followQueryProvider(fans).future);
    final first = container
        .read(followQueryProvider(recent).notifier)
        .followBack(1);
    await dispatched(3);
    requests[2].reply.complete({'code': 0});
    expect(await first, isA<Success>());
    await container.pump();
    await dispatched(4);
    requests[3].reply.complete(page([1], total: 1, attribute: 6));
    expect(
      (await container.read(followQueryProvider(fans).future))
          .items
          .single
          .attribute,
      6,
    );
    final remove = container.read(followQueryProvider(fans).notifier).remove(1);
    await dispatched(5);
    requests[4].reply.complete({'code': 0});
    expect(await remove, isA<Success>());
    await container.pump();
    await dispatched(6);
    requests[5].reply.complete(page([], total: 0));
    expect(
      (await container.read(followQueryProvider(recent).future)).items,
      isEmpty,
    );
    a.close();
    b.close();
  });

  test('写入成功使另一入口在途查询失效', () async {
    final a = container.listen(followQueryProvider(recent), (_, _) {});
    final b = container.listen(followQueryProvider(fans), (_, _) {});
    await dispatched(2);
    requests[0].reply.complete(page([1], total: 1));
    await container.read(followQueryProvider(recent).future);
    final write = container
        .read(followQueryProvider(recent).notifier)
        .followBack(1);
    await dispatched(3);
    requests[2].reply.complete({'code': 0});
    expect(await write, isA<Success>());
    await container.pump();
    await dispatched(4);
    requests[3].reply.complete(page([1], total: 1, attribute: 6));
    await container.read(followQueryProvider(fans).future);
    requests[1].reply.complete(page([1], total: 1));
    await Future<void>.delayed(Duration.zero);
    expect(current(fans).items.single.attribute, 6);
    a.close();
    b.close();
  });

  testWidgets('粉丝作为分享联系人可选择用户', (tester) async {
    container.dispose();
    container = ProviderContainer(
      overrides: [
        followQueryProvider(fans).overrideWith(() => _FixtureNotifier(fans)),
      ],
    );
    UserModel? selected;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: FollowTypePage(
            query: fans,
            showName: false,
            onSelect: (value) => selected = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('我的粉丝'), findsNothing);
    await tester.tap(find.text('选择用户'));
    expect(selected?.mid, 42);
    expect(selected?.name, '选择用户');
    await tester.pumpWidget(const SizedBox());
  });
}
