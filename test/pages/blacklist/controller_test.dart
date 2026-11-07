import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/blacklist/controller.dart';
import 'package:pili_aurora/pages/blacklist/view.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

class _Box<T> implements Box<T> {
  final stored = <dynamic, T>{};
  @override
  T? get(dynamic key, {T? defaultValue}) => stored[key] ?? defaultValue;
  @override
  Future<void> put(dynamic key, T value) async {
    stored[key] = value;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final requests = <_Pending>[];
  late ProviderContainer container;
  late ProviderSubscription<AsyncValue<BlackListState>> subscription;
  late Account account;
  LoginAccount login(int mid) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': 'fixture-$mid'}),
    null,
    null,
  )..activated = true;
  List<int> range(int first, int length) =>
      List.generate(length, (i) => first + i);
  Map<String, dynamic> page(List<int> ids, {int? total = 120}) => {
    'code': 0,
    'data': {
      'list': [
        for (final id in ids)
          {'mid': id, 'uname': 'user-$id', 'mtime': 0, 'face': ''},
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

  Future<void> loaded({int? total = 120}) async {
    await dispatched(1);
    requests[0].reply.complete(page(range(1, 50), total: total));
    await container.read(blackListProvider.future);
  }

  BlackListState current() => container.read(blackListProvider).requireValue;
  Future<void> select(Account value) async {
    Accounts.accountMode[AccountType.main.index] = value;
    await Accounts.refresh();
    await container.pump();
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
    account = login(123);
    Accounts.accountMode[AccountType.main.index] = account;
    container = ProviderContainer();
    subscription = container.listen(blackListProvider, (_, _) {});
  });
  tearDown(() {
    subscription.close();
    container.dispose();
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    for (final request in requests) {
      if (!request.reply.isCompleted) {
        request.reply.complete(page([], total: 0));
      }
    }
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('分页串行、按 UID 去重并发布不可变列表，短页停止', () async {
    await loaded();
    expect(current().items.clear, throwsUnsupportedError);
    final notifier = container.read(blackListProvider.notifier);
    final loading = notifier.loadMore();
    await dispatched(2);
    await notifier.loadMore();
    expect(requests, hasLength(2));
    expect(requests[1].options.extra['account'], same(account));
    expect(requests[1].options.queryParameters['pn'], 2);
    requests[1].reply.complete(page(range(45, 50)));
    await loading;
    expect(current().items.length, 94);
    final last = notifier.loadMore();
    await dispatched(3);
    requests[2].reply.complete(page(range(95, 26)));
    await last;
    expect(current().items.map((item) => item.mid), range(1, 120));
    expect(current().hasMore, isFalse);
  });

  test('分页失败保留内容和页码，等待显式重试', () async {
    await loaded();
    final notifier = container.read(blackListProvider.notifier);
    final loading = notifier.loadMore();
    await dispatched(2);
    requests[1].reply.complete({'code': -1, 'message': 'failed'});
    await loading;
    expect(current().items.length, 50);
    expect(current().nextPage, 2);
    expect(current().pageError, isNotNull);
    await notifier.loadMore();
    expect(requests, hasLength(2));
    final retry = notifier.loadMore(retry: true);
    await dispatched(3);
    expect(requests[2].options.queryParameters['pn'], 2);
    requests[2].reply.complete(page(range(51, 50)));
    await retry;
    expect(current().items.length, 100);
    expect(current().pageError, isNull);
  });

  test('初始查询失败进入错误状态，手动刷新后恢复', () async {
    await dispatched(1);
    final failed = expectLater(
      container.read(blackListProvider.future),
      throwsA(isA<Error>()),
    );
    requests[0].reply.complete({'code': -1, 'message': 'failed'});
    await failed;
    expect(container.read(blackListProvider).hasError, isTrue);
    expect(requests, hasLength(1));
    final retry = container.refresh(blackListProvider.future);
    await dispatched(2);
    requests[1].reply.complete(page([2], total: 1));
    expect((await retry).items.single.mid, 2);
  });

  test('刷新使旧分页失效，新查询独立完成且不继承加载标记', () async {
    await loaded();
    final old = container.read(blackListProvider.notifier).loadMore();
    await dispatched(2);
    container.invalidate(blackListProvider);
    await container.pump();
    await dispatched(3);
    requests[2].reply.complete(page([201], total: 1));
    await container.read(blackListProvider.future);
    requests[1].reply.complete(page(range(51, 50)));
    await old;
    expect(current().items.single.mid, 201);
    expect(current().isLoadingMore, isFalse);
  });

  test('同 mid 新凭据使查询失效；旧账号响应不能写入当前列表', () async {
    await dispatched(1);
    final replacement = login(123);
    Accounts.replaceCredentials(replacement);
    await container.pump();
    await dispatched(2);
    requests[1].reply.complete(page([2], total: 1));
    await container.read(blackListProvider.future);
    requests[0].reply.complete(page([1], total: 1));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(mainAccountProvider), same(replacement));
    expect(current().items.single.mid, 2);
  });

  test('移除失败保留列表，操作期间拒绝重复写入与分页', () async {
    await loaded();
    final notifier = container.read(blackListProvider.notifier);
    final removing = notifier.remove(1);
    await dispatched(2);
    expect(requests[1].options.path, Api.relationMod);
    expect(requests[1].options.extra['account'], same(account));
    expect(requests[1].options.extra['noRetry'], isTrue);
    expect((requests[1].options.data as Map)['csrf'], account.csrf);
    expect(await notifier.remove(1), isA<Error>());
    await notifier.loadMore();
    expect(requests, hasLength(2));
    requests[1].reply.complete({'code': -1, 'message': 'failed'});
    expect(await removing, isA<Error>());
    expect(current().total, 120);
    expect(current().items.first.mid, 1);
    expect(current().removingMid, isNull);
  });

  test('移除后重读边界页补齐前移项，后续分页不遗漏、不重复', () async {
    await loaded(total: 100);
    final notifier = container.read(blackListProvider.notifier);
    final removing = notifier.remove(1);
    await dispatched(2);
    requests[1].reply.complete({'code': 0});
    expect(await removing, isA<Success>());
    expect(current().total, 99);
    expect(current().nextPage, 1);
    final refill = notifier.loadMore();
    await dispatched(3);
    expect(requests[2].options.queryParameters['pn'], 1);
    requests[2].reply.complete(page(range(2, 50), total: 99));
    await refill;
    final last = notifier.loadMore();
    await dispatched(4);
    requests[3].reply.complete(page(range(52, 49), total: 99));
    await last;
    expect(current().items.map((item) => item.mid), range(2, 99));
    expect(current().hasMore, isFalse);
  });

  test('切号后的迟到移除不改变新账号列表或操作标记', () async {
    await loaded();
    final removing = container.read(blackListProvider.notifier).remove(1);
    await dispatched(2);
    await select(login(456));
    await dispatched(3);
    requests[2].reply.complete(page([2], total: 1));
    await container.read(blackListProvider.future);
    requests[1].reply.complete({'code': 0});
    expect(await removing, isA<Error>());
    expect(current().items.single.mid, 2);
    expect(current().removingMid, isNull);
  });

  test('未知总量的重复页无增长时停止自动分页', () async {
    await loaded(total: null);
    final loading = container.read(blackListProvider.notifier).loadMore();
    await dispatched(2);
    requests[1].reply.complete(page(range(1, 50), total: null));
    await loading;
    expect(current().items.length, 50);
    expect(current().hasMore, isFalse);
  });

  test('关闭最后订阅释放状态，重新进入从第一页读取', () async {
    await dispatched(1);
    subscription.close();
    await container.pump();
    expect(container.exists(blackListProvider), isFalse);
    expect(container.exists(mainAccountProvider), isFalse);
    requests[0].reply.complete(page([1], total: 1));
    await Future<void>.delayed(Duration.zero);
    subscription = container.listen(blackListProvider, (_, _) {});
    await dispatched(2);
    expect(requests[1].options.queryParameters['pn'], 1);
    requests[1].reply.complete(page([2], total: 1));
    expect(
      (await container.read(blackListProvider.future)).items.single.mid,
      2,
    );
  });

  testWidgets('账号切换加载期间隐藏旧名单与总数', (tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const GetMaterialApp(home: BlackListPage()),
      ),
    );
    await tester.runAsync(() async {
      await dispatched(1);
      requests[0].reply.complete(page([1], total: 1));
      await container.read(blackListProvider.future);
    });
    await tester.pumpAndSettle();
    expect(find.text('user-1'), findsOneWidget);
    expect(find.text('黑名单管理: 1'), findsOneWidget);
    await tester.runAsync(() => select(login(456)));
    await tester.pump();
    expect(find.text('user-1'), findsNothing);
    expect(find.text('黑名单管理: 1'), findsNothing);
    await tester.runAsync(() async {
      await dispatched(2);
      final failed = expectLater(
        container.read(blackListProvider.future),
        throwsA(isA<Error>()),
      );
      requests[1].reply.complete({'code': -1, 'message': 'failed'});
      await failed;
      await container.read(blackListProvider.notifier).loadMore();
      expect(
        await container.read(blackListProvider.notifier).remove(1),
        isA<Error>(),
      );
    });
    await tester.pumpAndSettle();
    expect(find.text('黑名单管理: 1'), findsNothing);
    expect(requests, hasLength(2));
    await tester.pumpWidget(const SizedBox());
    Get.reset();
  });
}
