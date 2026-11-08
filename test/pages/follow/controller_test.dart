import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/follow/controller.dart';
import 'package:pili_aurora/pages/follow/view.dart';
import 'package:pili_aurora/pages/follow/child/child_view.dart';
import 'package:pili_aurora/pages/follow_search/view.dart';
import 'package:pili_aurora/pages/group_panel/view.dart';
import 'package:pili_aurora/pages/follow_tag_sort/view.dart';
import 'package:pili_aurora/pages/share/view.dart' show UserModel;
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/request_utils.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  final dispatched = interceptor.waitForRequests;
  late ProviderContainer container;
  late LoginAccount account;
  const all = (mid: null, tagid: null, keyword: null);
  const group = (mid: null, tagid: 10, keyword: null);
  const search = (mid: null, tagid: null, keyword: '目标');
  LoginAccount login(int mid, String csrf) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': csrf}),
    null,
    null,
  )..activated = true;
  Map<String, dynamic> page(List<int> ids, {int? total = 45}) => {
    'code': 0,
    'data': {
      'list': [
        for (final id in ids)
          {'mid': id, 'uname': 'user-$id', 'face': '', 'attribute': 2},
      ],
      'total': ?total,
    },
  };
  Map<String, dynamic> tags() => {
    'code': 0,
    'data': [
      for (final id in [0, -10, 10, 11])
        {'tagid': id, 'name': '分组$id', 'count': 20},
    ],
  };
  List<int> range(int start, int count) =>
      List.generate(count, (i) => start + i);
  Future<void> select(LoginAccount next) async {
    Accounts.accountMode[AccountType.main.index] = next;
    await Accounts.refresh();
    await container.pump();
  }

  FollowingState current(FollowingQuery query) =>
      container.read(followingProvider(query)).requireValue;
  FollowTagsState groups() => container.read(followTagsProvider).requireValue;
  Future<void> loadList({int? total = 45}) async {
    await dispatched(1);
    requests.single.reply.complete(page(range(1, 20), total: total));
    await container.read(followingProvider(all).future);
  }

  Future<void> loadTags() async {
    await dispatched(1);
    requests.single.reply.complete(tags());
    await container.read(followTagsProvider.future);
  }

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
    (GStorage.setting as MemoryBox).data.clear();
    GStorage.localCache.put(
      LocalCacheKey.mixinKey,
      '01234567890123456789012345678901',
    );
    GStorage.localCache.put(
      LocalCacheKey.timeStamp,
      DateTime.now().millisecondsSinceEpoch,
    );
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
    Get.reset();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  test('全部关注、分组与关键词查询隔离，请求绑定账号和分页参数', () async {
    final subscriptions = [
      for (final query in [all, group, search])
        container.listen(followingProvider(query), (_, _) {}),
    ];
    await dispatched(3);
    expect(requests.map((r) => r.options.path).toSet(), {
      Api.followings,
      Api.followUpGroup,
      Api.followSearch,
    });
    for (final request in requests) {
      expect(request.options.extra['account'], same(account));
      expect(request.options.queryParameters['pn'], 1);
      if (request.options.path == Api.followUpGroup) {
        expect(request.options.queryParameters['tagid'], 10);
        request.reply.complete({
          'code': 0,
          'data': page([2])['data']['list'],
        });
      } else {
        request.reply.complete(
          page([request.options.path == Api.followSearch ? 3 : 1], total: 1),
        );
      }
    }
    for (final query in [all, group, search]) {
      await container.read(followingProvider(query).future);
    }
    expect(current(all).items.single.mid, 1);
    expect(current(group).items.single.mid, 2);
    expect(current(search).items.single.mid, 3);
    expect(() => current(all).items.clear(), throwsUnsupportedError);
    for (final subscription in subscriptions) {
      subscription.close();
    }
  });

  test('分页串行、失败不推进页码，显式重试后按 UID 去重', () async {
    final sub = container.listen(followingProvider(all), (_, _) {});
    await loadList();
    final notifier = container.read(followingProvider(all).notifier);
    final pending = notifier.loadMore();
    await notifier.loadMore();
    await dispatched(2);
    requests.last.reply.complete({'code': -1, 'message': 'failed'});
    await pending;
    expect(current(all).nextPage, 2);
    expect(current(all).items, hasLength(20));
    expect(current(all).pageError, isNotNull);
    await notifier.loadMore();
    expect(requests, hasLength(2));
    final retry = notifier.loadMore(retry: true);
    await dispatched(3);
    expect(requests.last.options.queryParameters['pn'], 2);
    requests.last.reply.complete(page(range(20, 20)));
    await retry;
    expect(current(all).items, hasLength(39));
    expect(current(all).nextPage, 3);
    expect(current(all).pageError, isNull);
    final last = notifier.loadMore();
    await dispatched(4);
    requests.last.reply.complete(page([40, 41, 42, 43, 44, 45]));
    await last;
    expect(current(all).hasMore, isFalse);
    sub.close();
  });

  test('无总数的分组按原始页大小分页，重复页停止', () async {
    final sub = container.listen(followingProvider(group), (_, _) {});
    await dispatched(1);
    requests.single.reply.complete({
      'code': 0,
      'data': page(range(1, 20))['data']['list'],
    });
    await container.read(followingProvider(group).future);
    expect(current(group).hasMore, isTrue);
    final more = container.read(followingProvider(group).notifier).loadMore();
    await dispatched(2);
    requests.last.reply.complete({
      'code': 0,
      'data': page(range(1, 20))['data']['list'],
    });
    await more;
    expect(current(group).hasMore, isFalse);
    sub.close();
  });

  test('排序切换使旧分页失效，关键词查询不受列表排序影响', () async {
    final a = container.listen(followingProvider(all), (_, _) {});
    await loadList();
    final b = container.listen(followingProvider(search), (_, _) {});
    await dispatched(2);
    requests.last.reply.complete(page([9], total: 1));
    await container.read(followingProvider(search).future);
    final pending = container.read(followingProvider(all).notifier).loadMore();
    await dispatched(3);
    container.read(followOrderProvider.notifier).toggle();
    await container.pump();
    await dispatched(4);
    expect(requests.last.options.queryParameters['order_type'], 'attention');
    requests.last.reply.complete(page([50], total: 1));
    await container.read(followingProvider(all).future);
    requests[2].reply.complete(page(range(21, 20)));
    await pending;
    expect(current(all).items.single.mid, 50);
    expect(current(search).items.single.mid, 9);
    a.close();
    b.close();
  });

  for (final sameMid in [false, true]) {
    test('切换${sameMid ? '同 UID 凭据' : '账号'}隔离查询与旧分页', () async {
      final sub = container.listen(followingProvider(all), (_, _) {});
      await loadList();
      final pending = container
          .read(followingProvider(all).notifier)
          .loadMore();
      await dispatched(2);
      final next = login(sameMid ? 100 : 200, 'new');
      await select(next);
      await dispatched(3);
      expect(requests.last.options.extra['account'], same(next));
      expect(requests.last.options.queryParameters['vmid'], next.mid);
      requests.last.reply.complete(page([99], total: 1));
      await container.read(followingProvider(all).future);
      requests[1].reply.complete(page(range(21, 20)));
      await pending;
      expect(current(all).items.single.mid, 99);
      sub.close();
    });
  }

  test('刷新和释放使旧分页失效，查询失败后的旧快照不能继续分页', () async {
    final sub = container.listen(followingProvider(all), (_, _) {});
    await loadList();
    final pending = container.read(followingProvider(all).notifier).loadMore();
    await dispatched(2);
    final refresh = container.refresh(followingProvider(all).future);
    await dispatched(3);
    requests.last.reply.complete({'code': -1, 'message': 'failed'});
    await expectLater(refresh, throwsA(anything));
    await container.read(followingProvider(all).notifier).loadMore();
    expect(requests, hasLength(3));
    requests[1].reply.complete(page([99], total: 1));
    await pending;
    expect(container.read(followingProvider(all)).hasError, isTrue);
    sub.close();
    await container.pump();
    expect(container.exists(followingProvider(all)), isFalse);
  });

  test('分组新建、改名、删除与排序使用指定账号及 CSRF，快照不原地修改', () async {
    final sub = container.listen(followTagsProvider, (_, _) {});
    await loadTags();
    final original = groups();
    expect(original.tags.clear, throwsUnsupportedError);
    final notifier = container.read(followTagsProvider.notifier);
    final create = notifier.create('新分组', original.source);
    await dispatched(2);
    expect(groups().isSaving, isTrue);
    final repeated = await notifier.create('重复', original.source);
    expect(repeated.isSuccess, isFalse);
    expect(requests, hasLength(2));
    requests.last.reply.complete({
      'code': 0,
      'data': {'tagid': 12},
    });
    final created = (await create).data;
    expect(created.id, 12);
    expect(created.source, same(groups().source));
    expect(original.tags, hasLength(4));
    expect(groups().tags, hasLength(5));
    final rename = notifier.rename(12, '新名称', groups().source);
    await dispatched(3);
    requests.last.reply.complete({'code': 0});
    await rename;
    expect(groups().tags.last.name, '新名称');
    final ids = [12, 11, 10];
    final sort = notifier.reorder(ids, groups().source);
    ids.clear();
    await dispatched(4);
    expect((requests.last.options.data as Map)['tagids'], '12,11,10');
    requests.last.reply.complete({'code': 0});
    await sort;
    expect(groups().tags.map((tag) => tag.id), [0, -10, 12, 11, 10]);
    final remove = notifier.remove(12, groups().source);
    await dispatched(5);
    requests.last.reply.complete({'code': 0});
    await remove;
    expect(groups().tags.map((tag) => tag.id), [0, -10, 11, 10]);
    for (final request in requests.skip(1)) {
      expect(request.options.extra['account'], same(account));
      expect(request.options.extra['noRetry'], isTrue);
      expect((request.options.data as Map)['csrf'], 'old');
    }
    sub.close();
  });

  test('分组失败恢复确认状态，拒绝过期来源与非法排序', () async {
    final sub = container.listen(followTagsProvider, (_, _) {});
    await loadTags();
    final before = groups();
    final notifier = container.read(followTagsProvider.notifier);
    final pending = notifier.rename(10, '失败名称', before.source);
    await dispatched(2);
    requests.last.reply.complete({'code': -1, 'message': 'failed'});
    expect((await pending).isSuccess, isFalse);
    expect(identical(groups(), before), isTrue);
    expect(
      (await notifier.reorder([10, 10], before.source)).isSuccess,
      isFalse,
    );
    expect((await notifier.remove(0, before.source)).isSuccess, isFalse);
    expect((await notifier.create('  ', before.source)).isSuccess, isFalse);
    final rename = notifier.rename(10, '已更新', before.source);
    await dispatched(3);
    requests.last.reply.complete({'code': 0});
    await rename;
    expect((await notifier.remove(11, before.source)).isSuccess, isFalse);
    expect(requests, hasLength(3));
    sub.close();
  });

  test('分组写入途中切号后不回写新账号，旧排序页来源不能再写入', () async {
    final sub = container.listen(followTagsProvider, (_, _) {});
    await loadTags();
    final source = groups().source;
    final pending = container
        .read(followTagsProvider.notifier)
        .create('旧账号', source);
    await dispatched(2);
    final next = login(200, 'new');
    await select(next);
    await dispatched(3);
    requests.last.reply.complete(tags());
    await container.read(followTagsProvider.future);
    requests[1].reply.complete({
      'code': 0,
      'data': {'tagid': 99},
    });
    expect((await pending).isSuccess, isFalse);
    expect(groups().tags.any((tag) => tag.id == 99), isFalse);
    expect(
      (await container.read(followTagsProvider.notifier).reorder([
        11,
        10,
      ], source)).isSuccess,
      isFalse,
    );
    expect(requests, hasLength(3));
    sub.close();
  });

  test('成员分组保存刷新列表和服务端计数，调用后修改选择集合不影响请求', () async {
    final a = container.listen(followTagsProvider, (_, _) {});
    await loadTags();
    final b = container.listen(followingProvider(all), (_, _) {});
    await dispatched(2);
    requests.last.reply.complete(page([1], total: 1));
    await container.read(followingProvider(all).future);
    final selected = {10};
    final pending = container
        .read(followTagsProvider.notifier)
        .assign(1, selected, groups().source);
    selected.clear();
    await dispatched(3);
    expect((requests.last.options.data as Map)['tagids'], '10');
    requests.last.reply.complete({'code': 0});
    expect((await pending).isSuccess, isTrue);
    await container.pump();
    await dispatched(5);
    expect(requests.skip(3).map((r) => r.options.path).toSet(), {
      Api.followings,
      Api.followUpTag,
    });
    a.close();
    b.close();
  });

  testWidgets('搜索输入替换立即隐藏旧结果，乱序响应不覆盖当前关键词，清空后可重查', (tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: FollowSearchPage()),
      ),
    );
    await tester.enterText(find.byType(TextField), '甲');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await dispatched(1);
    });
    expect(requests.single.options.queryParameters['name'], '甲');
    await tester.enterText(find.byType(TextField), '乙');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await dispatched(2);
      requests.last.reply.complete(page([2], total: 1));
      await Future<void>.delayed(Duration.zero);
      requests.first.reply.complete(page([1], total: 1));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('user-2'), findsOneWidget);
    expect(find.text('user-1'), findsNothing);
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    expect(find.text('user-2'), findsNothing);
    await tester.enterText(find.byType(TextField), '乙');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await dispatched(3);
      requests.last.reply.complete(page([3], total: 1));
    });
    await tester.pumpAndSettle();
    expect(find.text('user-3'), findsOneWidget);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump();
    expect(
      container.exists(
        followingProvider((mid: null, tagid: null, keyword: '乙')),
      ),
      isFalse,
    );
  });

  testWidgets('主关注页分组变更保留当前分组，删除当前分组回到全部关注', (tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: FollowPage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await dispatched(1);
      requests.single.reply.complete(tags());
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await dispatched(2);
      expect(requests.last.options.path, Api.followings);
      requests.last.reply.complete(page([1], total: 1));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('全部关注(1)'), findsOneWidget);
    await tester.tap(find.text('分组10(20) '));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await dispatched(3);
      final request = requests.lastWhere(
        (r) => r.options.queryParameters['tagid'] == 10,
      );
      request.reply.complete({
        'code': 0,
        'data': page([10])['data']['list'],
      });
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('user-10'), findsOneWidget);
    await tester.runAsync(() async {
      final rename = container
          .read(followTagsProvider.notifier)
          .rename(10, '改名', groups().source);
      await dispatched(4);
      requests.last.reply.complete({'code': 0});
      await rename;
    });
    await tester.pumpAndSettle();
    expect(find.text('改名(20) '), findsOneWidget);
    expect(find.text('user-10'), findsOneWidget);
    await tester.runAsync(() async {
      final remove = container
          .read(followTagsProvider.notifier)
          .remove(10, groups().source);
      await dispatched(5);
      requests.last.reply.complete({'code': 0});
      await remove;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      for (final request in requests.where((r) => !r.reply.isCompleted)) {
        request.reply.complete(
          request.options.path == Api.followUpGroup
              ? {'code': 0, 'data': []}
              : page([1], total: 1),
        );
      }
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('改名(20) '), findsNothing);
    expect(find.text('user-1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('分组面板勾选不修改共享计数，切号后隐藏分组并禁止保存', (tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: GroupPanel(mid: 1, tags: const [10], account: account),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await dispatched(1);
      requests.single.reply.complete(tags());
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    final before = groups();
    await tester.tap(find.text('分组10 (20)'));
    await tester.pumpAndSettle();
    expect(find.text('分组10 (19)'), findsOneWidget);
    expect(groups().tags.firstWhere((tag) => tag.id == 10).count, 20);
    expect(identical(groups(), before), isTrue);
    await tester.runAsync(() => select(login(200, 'new')));
    await tester.pump();
    expect(find.text('分组10 (19)'), findsNothing);
    expect(find.text('账号已切换，请重新打开'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('分组面板刷新后拒绝旧草稿，迟到点击也不发送保存', (tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: GroupPanel(mid: 1, tags: const [10], account: account),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await dispatched(1);
      requests.single.reply.complete(tags());
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('分组10 (20)'));
    await tester.pumpAndSettle();
    final save = tester
        .widget<FilledButton>(find.byType(FilledButton))
        .onPressed!;
    container.invalidate(followTagsProvider);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await dispatched(2);
      requests.last.reply.complete(tags());
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      save();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('分组已更新，请重新打开'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(requests, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('分组面板可沿自身创建结果继续编辑和保存', (tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: GetMaterialApp(
          builder: FlutterSmartDialog.init(),
          home: Scaffold(
            body: GroupPanel(mid: 1, tags: const [10], account: account),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await dispatched(1);
      requests.single.reply.complete(tags());
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建分组'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '新分组');
    await tester.tap(find.text('确认'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await dispatched(2);
      requests.last.reply.complete({
        'code': 0,
        'data': {'tagid': 12},
      });
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('分组已更新，请重新打开'), findsNothing);
    expect(find.text('新分组 (1)'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await dispatched(3);
      expect((requests.last.options.data as Map)['tagids'], '10,12');
      requests.last.reply.complete({'code': -1, 'message': 'failed'});
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    final dismissal = SmartDialog.dismiss(status: SmartStatus.allToast);
    await tester.pumpAndSettle();
    await dismissal;
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('排序页持有独立顺序，来源变化后禁止覆盖新分组', (tester) async {
    late ProviderSubscription<AsyncValue<FollowTagsState>> sub;
    await tester.runAsync(() async {
      sub = container.listen(followTagsProvider, (_, _) {});
      await loadTags();
    });
    final before = groups();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: FollowTagSortPage(initial: before)),
      ),
    );
    await tester.pumpAndSettle();
    final reorder = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    reorder.onReorderItem!(1, 0);
    await tester.pump();
    expect(groups().tags.map((tag) => tag.id), [0, -10, 10, 11]);
    await tester.runAsync(() async {
      final rename = container
          .read(followTagsProvider.notifier)
          .rename(10, '新名称', before.source);
      await dispatched(2);
      requests.last.reply.complete({'code': 0});
      await rename;
    });
    await tester.pumpAndSettle();
    expect(find.text('分组或账号已更新，请返回后重试'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '完成'))
          .onPressed,
      isNull,
    );
    sub.close();
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const SizedBox()),
    );
    await tester.pump();
  });

  testWidgets('关注列表保留分享选人回调，加载新账号失败不展示旧用户', (tester) async {
    UserModel? selected;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: FollowChildPage(onSelect: (user) => selected = user),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await dispatched(1);
      requests.single.reply.complete(page([1], total: 1));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('user-1'));
    expect(selected?.mid, 1);
    await tester.runAsync(() async {
      await select(login(200, 'new'));
      await dispatched(2);
      requests.last.reply.complete({'code': -1, 'message': '新账号失败'});
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('user-1'), findsNothing);
    expect(find.textContaining('新账号失败'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('关注交互绑定发起账号，迟到结果不回调已切换的页面', (tester) async {
    var callbacks = 0;
    late BuildContext context;
    await tester.pumpWidget(
      GetMaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold();
          },
        ),
      ),
    );
    final pending = RequestUtils.actionRelationMod(
      context: context,
      account: account,
      mid: 1,
      isFollow: false,
      afterMod: (_) => callbacks++,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async {
      await dispatched(1);
      expect(requests.single.options.extra['account'], same(account));
      expect(requests.single.options.extra['noRetry'], isTrue);
      expect((requests.single.options.data as Map)['csrf'], 'old');
      await select(login(200, 'new'));
      requests.single.reply.complete({'code': 0});
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    await pending;
    expect(callbacks, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
