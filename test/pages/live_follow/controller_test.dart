import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart' as loading;
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/live/live_follow/data.dart';
import 'package:pili_aurora/pages/live_follow/controller.dart';
import 'package:pili_aurora/pages/live_follow/view.dart';
import 'package:pili_aurora/services/account_providers.dart';
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
  late ProviderSubscription<AsyncValue<LiveFollowState>> subscription;
  late Account account;
  LoginAccount login(int mid) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': 'fixture-$mid'}),
    null,
    null,
  )..activated = true;
  Map<String, dynamic> room(int id, {bool live = true}) => {
    'roomid': id,
    'uname': 'user-$id',
    'title': 'room-$id',
    'room_cover': '',
    'area_name': 'area',
    'live_status': live ? 1 : 0,
  };
  Map<String, dynamic> page(
    List<Map<String, dynamic>> rooms, {
    int? pages = 3,
    int? count = 27,
    int? liveCount = 20,
    int size = 9,
  }) => {
    'code': 0,
    'data': {
      'list': rooms,
      'pageSize': size,
      'totalPage': ?pages,
      'count': ?count,
      'live_count': ?liveCount,
    },
  };
  Future<void> loaded() async {
    await dispatched(1);
    requests[0].reply.complete(page([room(1)]));
    await container.read(liveFollowProvider.future);
  }

  LiveFollowState current() => container.read(liveFollowProvider).requireValue;
  Future<void> select(Account value) async {
    Accounts.accountMode[AccountType.main.index] = value;
    await Accounts.refresh();
    await container.pump();
  }

  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
    Accounts.account = MemoryBox<LoginAccount>();
    AnonymousAccount().activated = true;
    Request();
    Request.dio.interceptors.clear();
    Request.dio.interceptors.add(
      interceptor,
    );
  });
  setUp(() async {
    requests.clear();
    account = login(123);
    Accounts.accountMode[AccountType.main.index] = account;
    container = ProviderContainer();
    subscription = container.listen(liveFollowProvider, (_, _) {});
    // 首包进入夹具后才开始用例，使退出时能完成请求，不污染下一个用例。
    await dispatched(1);
  });
  tearDown(() {
    subscription.close();
    container.dispose();
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    for (final request in requests) {
      if (!request.reply.isCompleted) {
        request.reply.complete(page([], pages: 0, liveCount: 0));
      }
    }
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  test('原始条目数量在过滤离线直播间后仍可用于分页', () {
    final data = LiveFollowData.fromJson({
      'list': [room(1, live: false), room(2)],
    });
    expect(data.sourceCount, 2);
    expect(data.list!.single.roomid, 2);
  });

  test('按远端总页数串行分页、按房间去重并发布不可变列表', () async {
    await dispatched(1);
    expect(requests.single.options.path, Api.liveFollow);
    expect(requests.single.options.extra['account'], same(account));
    requests[0].reply.complete(page([room(1), room(2)], liveCount: 4));
    await container.read(liveFollowProvider.future);
    expect(current().items.clear, throwsUnsupportedError);
    final notifier = container.read(liveFollowProvider.notifier);
    final pending = notifier.loadMore();
    await dispatched(2);
    await notifier.loadMore();
    expect(requests, hasLength(2));
    expect(requests[1].options.queryParameters['page'], 2);
    requests[1].reply.complete(page([room(2), room(3)], liveCount: 4));
    await pending;
    expect(current().items.map((item) => item.roomid), [1, 2, 3]);
    final last = notifier.loadMore();
    await dispatched(3);
    requests[2].reply.complete(page([room(4)], liveCount: 4));
    await last;
    expect(current().hasMore, isFalse);
    expect(current().items.map((item) => item.roomid), [1, 2, 3, 4]);
  });

  test('空的过滤页不提前结束，后页仍能加载正在直播的房间', () async {
    await dispatched(1);
    requests[0].reply.complete(
      page([room(1, live: false)], pages: 2, liveCount: 1),
    );
    await container.read(liveFollowProvider.future);
    expect(current().items, isEmpty);
    expect(current().hasMore, isTrue);
    final pending = container.read(liveFollowProvider.notifier).loadMore();
    await dispatched(2);
    requests[1].reply.complete(page([room(2)], pages: 2, liveCount: 1));
    await pending;
    expect(current().items.single.roomid, 2);
    expect(current().hasMore, isFalse);
  });

  test('缺少总页数时使用原始总数，缺少全部分页信息时限制无增长页', () async {
    await dispatched(1);
    requests[0].reply.complete(
      page(
        [room(1, live: false)],
        pages: null,
        count: 2,
        liveCount: 1,
        size: 1,
      ),
    );
    await container.read(liveFollowProvider.future);
    expect(current().hasMore, isTrue);
    final pending = container.read(liveFollowProvider.notifier).loadMore();
    await dispatched(2);
    requests[1].reply.complete(
      page([room(2)], pages: null, count: 2, liveCount: 1, size: 1),
    );
    await pending;
    expect(current().hasMore, isFalse);
    final restart = container.refresh(liveFollowProvider.future);
    await dispatched(3);
    requests[2].reply.complete(
      page(
        [for (var i = 0; i < 9; i++) room(i, live: false)],
        pages: null,
        count: null,
        liveCount: null,
      ),
    );
    await restart;
    for (var i = 0; i < 4; i++) {
      final next = container.read(liveFollowProvider.notifier).loadMore();
      await dispatched(4 + i);
      requests[3 + i].reply.complete(
        page(
          [for (var j = 0; j < 9; j++) room(j, live: false)],
          pages: null,
          count: null,
          liveCount: null,
        ),
      );
      await next;
    }
    expect(current().emptyPages, 5);
    expect(current().hasMore, isFalse);
  });

  test('分页失败保留房间、人数和页码，等待显式重试', () async {
    await loaded();
    final notifier = container.read(liveFollowProvider.notifier);
    final pending = notifier.loadMore();
    await dispatched(2);
    requests[1].reply.complete({'code': -1, 'message': 'failed'});
    await pending;
    expect(current().items.single.roomid, 1);
    expect(current().liveCount, 20);
    expect(current().nextPage, 2);
    expect(current().pageError, isNotNull);
    await notifier.loadMore();
    expect(requests, hasLength(2));
    final retry = notifier.loadMore(retry: true);
    await dispatched(3);
    expect(requests[2].options.queryParameters['page'], 2);
    requests[2].reply.complete(page([room(2)]));
    await retry;
    expect(current().items.length, 2);
    expect(current().pageError, isNull);
  });

  test('刷新使旧分页失效并换用新的查询所有者', () async {
    await loaded();
    final oldSource = current().source;
    final pending = container.read(liveFollowProvider.notifier).loadMore();
    await dispatched(2);
    final refresh = container.refresh(liveFollowProvider.future);
    await dispatched(3);
    requests[2].reply.complete(page([room(3)], pages: 1, liveCount: 1));
    await refresh;
    requests[1].reply.complete(page([room(2)]));
    await pending;
    expect(current().items.single.roomid, 3);
    expect(current().source, isNot(same(oldSource)));
    expect(current().isLoadingMore, isFalse);
  });

  test('同 mid 更换凭据后旧响应不覆盖新账号结果', () async {
    await dispatched(1);
    final replacement = login(123);
    Accounts.replaceCredentials(replacement);
    await container.pump();
    await dispatched(2);
    expect(requests[1].options.extra['account'], same(replacement));
    requests[1].reply.complete(page([room(2)], pages: 1, liveCount: 1));
    await container.read(liveFollowProvider.future);
    requests[0].reply.complete(page([room(1)]));
    await Future<void>.delayed(Duration.zero);
    expect(current().items.single.roomid, 2);
  });

  test('最后订阅释放后状态销毁，重进页面从第一页读取', () async {
    await dispatched(1);
    subscription.close();
    await container.pump();
    expect(container.exists(liveFollowProvider), isFalse);
    expect(container.exists(mainAccountProvider), isFalse);
    requests[0].reply.complete(page([room(1)]));
    await Future<void>.delayed(Duration.zero);
    subscription = container.listen(liveFollowProvider, (_, _) {});
    await dispatched(2);
    expect(requests[1].options.queryParameters['page'], 1);
    requests[1].reply.complete(page([room(2)], pages: 1, liveCount: 1));
    expect(
      (await container.read(liveFollowProvider.future)).items.single.roomid,
      2,
    );
  });

  test('首包失败可以手动重试，退出登录不再查询直播关注', () async {
    await dispatched(1);
    final failed = expectLater(
      container.read(liveFollowProvider.future),
      throwsA(isA<loading.Error>()),
    );
    requests[0].reply.complete({'code': -1, 'message': 'failed'});
    await failed;
    final retry = container.refresh(liveFollowProvider.future);
    await dispatched(2);
    requests[1].reply.complete(page([room(2)], pages: 1, liveCount: 1));
    await retry;
    await select(AnonymousAccount());
    await expectLater(
      container.read(liveFollowProvider.future),
      throwsA(isA<loading.Error>()),
    );
    expect(container.read(liveFollowProvider).error, isA<loading.Error>());
    expect(requests, hasLength(2));
  });

  test('切号查询失败后不能拿旧快照继续分页', () async {
    await loaded();
    await select(login(456));
    await dispatched(2);
    final failed = expectLater(
      container.read(liveFollowProvider.future),
      throwsA(isA<loading.Error>()),
    );
    requests[1].reply.complete({'code': -1, 'message': 'failed'});
    await failed;
    await container.read(liveFollowProvider.notifier).loadMore();
    await container.read(liveFollowProvider.notifier).loadMore(retry: true);
    expect(container.read(liveFollowProvider).hasError, isTrue);
    expect(requests, hasLength(2));
  });

  testWidgets('首包全是离线房间时自动补后页，切号加载时隐藏旧房间和人数', (tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const GetMaterialApp(home: LiveFollowPage()),
      ),
    );
    await tester.runAsync(() async {
      await dispatched(1);
      requests[0].reply.complete(
        page([room(1, live: false)], pages: 2, liveCount: 1),
      );
      await container.read(liveFollowProvider.future);
    });
    for (var i = 0; i < 10 && requests.length < 2; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }
    expect(requests, hasLength(2));
    await tester.runAsync(() async {
      await dispatched(2);
      requests[1].reply.complete(page([room(2)], pages: 2, liveCount: 1));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('room-2'), findsOneWidget);
    expect(find.text('1人正在直播'), findsOneWidget);
    await tester.runAsync(() => select(login(456)));
    await tester.pump();
    expect(find.text('room-2'), findsNothing);
    expect(find.text('1人正在直播'), findsNothing);
    await tester.runAsync(() async {
      await dispatched(3);
      final failed = expectLater(
        container.read(liveFollowProvider.future),
        throwsA(isA<loading.Error>()),
      );
      requests[2].reply.complete({'code': -1, 'message': 'failed'});
      await failed;
    });
    await tester.pumpAndSettle();
    expect(find.text('1人正在直播'), findsNothing);
    expect(requests, hasLength(3));
    await tester.pumpWidget(const SizedBox());
    Get.reset();
  });
}
