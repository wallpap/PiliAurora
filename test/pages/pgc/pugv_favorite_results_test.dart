import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/video/introduction/pgc/controller.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/result.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/user_status.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  late PgcIntroController controller;
  LoginAccount login(String csrf) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': csrf}),
    null,
    null,
  )..activated = true;
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
  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(),
      ),
    );
    controller = PgcIntroController()
      ..seasonId = 1
      ..pgcItem = PgcInfoModel(userStatus: UserStatus(favored: 0));
  }

  Future<void> finish(WidgetTester tester) async {
    final dismissed = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismissed;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  testWidgets('课程收藏互斥且只在确认成功后改变状态', (tester) async {
    await mount(tester);
    for (final response in [
      {'code': -403, 'message': '拒绝收藏'},
      {'code': 0},
    ]) {
      final index = requests.length;
      late Future<void> pending;
      await tester.runAsync(() async {
        pending = controller.onFavPugv();
        await controller.onFavPugv();
        await interceptor.waitForRequests(index + 1);
      });
      expect(controller.pugvFavBusy.value, isTrue);
      expect((requests.last.options.data as Map)['csrf'], 'old');
      expect(requests.last.options.extra['account'], same(Accounts.main));
      await resolve(tester, index, response);
      await tester.runAsync(() async => await pending);
      expect(controller.pugvFavBusy.value, isFalse);
      expect(controller.pugvFavState.value.data, response['code'] == 0);
    }
    await finish(tester);
  });
  testWidgets('课程收藏待确认后先查询，查询失败仍可重试', (tester) async {
    await mount(tester);
    late Future<void> pending;
    await tester.runAsync(() async {
      pending = controller.onFavPugv();
      await interceptor.waitForRequests(1);
    });
    await resolve(tester, 0, {'message': 'missing code'});
    await tester.runAsync(() async => await pending);
    expect(controller.pugvFavState.value, isA<UnknownResult>());
    await tester.runAsync(() async {
      pending = controller.onFavPugv();
      await interceptor.waitForRequests(2);
    });
    await resolve(tester, 1, {'code': -403, 'message': '查询失败'});
    await tester.runAsync(() async => await pending);
    expect(controller.pugvFavState.value, isA<Error>());
    await tester.runAsync(() async {
      pending = controller.onFavPugv();
      await interceptor.waitForRequests(3);
    });
    await resolve(tester, 2, {
      'code': 0,
      'data': {
        'user_status': {'favored': 1},
      },
    });
    await tester.runAsync(() async => await pending);
    expect(controller.pugvFavState.value.data, isTrue);
    expect(requests.last.options.queryParameters['season_id'], 1);
    await finish(tester);
  });
  testWidgets('切换账号与课程后迟到收藏回执失效', (tester) async {
    await mount(tester);
    late Future<void> pending;
    await tester.runAsync(() async {
      pending = controller.onFavPugv();
      await interceptor.waitForRequests(1);
    });
    Accounts.accountMode[AccountType.main.index] = login('new');
    controller.seasonId = 2;
    await resolve(tester, 0, {'code': 0});
    await tester.runAsync(() async => await pending);
    expect(controller.pugvFavState.value.data, isFalse);
    expect(find.text('收藏成功'), findsNothing);
    await finish(tester);
  });
}
