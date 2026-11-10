import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/fav/account_favorite_controller.dart';
import 'package:pili_aurora/pages/fav/cheese/controller.dart';
import 'package:pili_aurora/pages/fav/topic/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  late AccountFavoriteController<dynamic, dynamic> controller;
  LoginAccount login(String csrf) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': csrf}),
    null,
    null,
  )..activated = true;
  Map<String, dynamic> body(bool cheese, List<int> ids) => {
    'code': 0,
    'data': cheese
        ? {
            'items': [
              for (final id in ids) {'season_id': id},
            ],
            'page': {'next': false},
          }
        : {
            'topic_list': {
              'topic_items': [
                for (final id in ids) {'id': id},
              ],
              'page_info': {'total': ids.length},
            },
          },
  };
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Accounts.account = MemoryBox<LoginAccount>();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() {
    requests.clear();
    Accounts.accountMode[AccountType.main.index] = login('old');
  });
  tearDown(() => controller.onDelete());
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> resolve(WidgetTester tester, int index, Object response) =>
      tester.runAsync(() async {
        requests[index].reply.complete(response);
        await Future<void>.delayed(Duration.zero);
      });
  Future<void> mount(WidgetTester tester, bool cheese) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(),
      ),
    );
    controller = cheese ? FavCheeseController() : FavTopicController();
    await tester.runAsync(() async {
      controller.onStart();
      await interceptor.waitForRequests(1);
      requests[0].reply.complete(body(cheese, [1, 2]));
      await Future<void>.delayed(Duration.zero);
    });
  }

  Future<void> finish(WidgetTester tester) async {
    final dismissed = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismissed;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  for (final cheese in [true, false]) {
    final name = cheese ? '课程' : '话题';
    for (final response in [
      {'code': -403, 'message': '拒绝取消'},
      {'message': 'missing code'},
    ]) {
      testWidgets('$name 取消互斥，拒绝与待确认保留内容和重试入口', (tester) async {
        await mount(tester, cheese);
        final source = controller.loadingState.value.data!;
        final action = controller.removalAction(1)!;
        late Future<void> pending;
        await tester.runAsync(() async {
          pending = action();
          await action();
          await interceptor.waitForRequests(2);
        });
        expect(requests.last.options.extra['account'], same(Accounts.main));
        expect((requests.last.options.data as Map)['csrf'], 'old');
        await resolve(tester, 1, response);
        await tester.runAsync(() async => await pending);
        expect(controller.loadingState.value.data, same(source));
        expect(source, hasLength(2));
        expect(controller.removalAction(1), isNotNull);
        await finish(tester);
      });
    }
    testWidgets('$name 迟到确认、查询与删除均不能操作同UID的新凭据', (tester) async {
      await mount(tester, cheese);
      final staleAction = controller.removalAction(1)!;
      late Future<void> removal;
      await tester.runAsync(() async {
        removal = staleAction();
        await interceptor.waitForRequests(2);
        Accounts.replaceCredentials(login('new'));
        await interceptor.waitForRequests(3);
      });
      expect(requests[2].options.extra['account'], same(Accounts.main));
      await resolve(tester, 2, body(cheese, [3]));
      await resolve(tester, 1, {'code': 0});
      await tester.runAsync(() async {
        await removal;
        await staleAction();
      });
      expect(requests, hasLength(3));
      expect(controller.itemId(controller.loadingState.value.data!.single), 3);
      await finish(tester);
    });
    testWidgets('$name 删除成功重读偏移分页边界，刷新期间旧确认失效', (tester) async {
      await mount(tester, cheese);
      final action = controller.removalAction(1)!;
      late Future<void> pending;
      await tester.runAsync(() async {
        pending = action();
        await interceptor.waitForRequests(2);
      });
      await resolve(tester, 1, {'code': 0});
      await tester.runAsync(() async {
        await interceptor.waitForRequests(3);
        await action();
      });
      await resolve(tester, 2, body(cheese, [2, 3]));
      await tester.runAsync(() async => await pending);
      expect(controller.loadingState.value.data!.map(controller.itemId), [
        2,
        3,
      ]);
      await finish(tester);
    });
  }
}
