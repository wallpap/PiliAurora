import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/space/space/data.dart';
import 'package:pili_aurora/pages/member/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  late MemberController controller;
  late BuildContext context;
  LoginAccount login(String csrf) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': csrf}),
    null,
    null,
  )..activated = true;
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() {
    requests.clear();
    Accounts.accountMode[AccountType.main.index] = login('old');
    controller = MemberController(mid: 2)
      ..loadingState.value = Success(SpaceData())
      ..isFollowed = 1;
    controller.relation.value = 4;
  });
  tearDown(() {
    controller.onDelete();
    Get.reset();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold();
          },
        ),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
  }

  Future<void> resolve(WidgetTester tester, int index, Object body) =>
      tester.runAsync(() async {
        requests[index].reply.complete(body);
        await Future<void>.delayed(Duration.zero);
      });
  Future<void> finish(WidgetTester tester) async {
    final dismissed = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismissed;
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('移除粉丝互斥，拒绝保留关系并可重试', (tester) async {
    await mount(tester);
    late Future<void> pending;
    await tester.runAsync(() async {
      pending = controller.onRemoveFan();
      await controller.onRemoveFan();
      await interceptor.waitForRequests(1);
    });
    expect(requests, hasLength(1));
    expect(requests.single.options.extra['account'], same(Accounts.main));
    expect((requests.single.options.data as Map)['csrf'], 'old');
    await resolve(tester, 0, {'code': -403, 'message': '拒绝'});
    await tester.runAsync(() => pending);
    expect(controller.isFollowed, 1);
    expect(controller.relation.value, 4);
    await tester.runAsync(() async {
      pending = controller.onRemoveFan();
      await interceptor.waitForRequests(2);
    });
    await resolve(tester, 1, {'code': 0});
    await tester.runAsync(() => pending);
    expect(controller.isFollowed, isNull);
    expect(controller.relation.value, 2);
    await finish(tester);
  });

  testWidgets('刷新使迟到移除粉丝失败失效，不改新关系或弹出旧错误', (tester) async {
    await mount(tester);
    late Future<void> pending;
    late Future<void> refresh;
    await tester.runAsync(() async {
      pending = controller.onRemoveFan();
      await interceptor.waitForRequests(1);
      refresh = controller.onRefresh();
      await interceptor.waitForRequests(2);
    });
    await resolve(tester, 1, {
      'code': 0,
      'data': {'relation': 2},
    });
    await tester.runAsync(() => refresh);
    await resolve(tester, 0, {'code': -403, 'message': '旧移除错误'});
    await tester.runAsync(() => pending);
    await tester.pumpAndSettle();
    expect(controller.relation.value, 2);
    expect(find.text('旧移除错误'), findsNothing);
    await finish(tester);
  });

  testWidgets('拉黑确认弹窗切号后不发送写入，同账号的错误明确提示', (tester) async {
    await mount(tester);
    final first = controller.blockUser(context);
    await tester.pumpAndSettle();
    Accounts.accountMode[AccountType.main.index] = login('new');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    await first;
    expect(requests, isEmpty);
    late Future<void> second;
    second = controller.blockUser(context);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => interceptor.waitForRequests(1));
    await resolve(tester, 0, {'code': -403, 'message': '无法拉黑'});
    await tester.runAsync(() => second);
    await tester.pumpAndSettle();
    expect(controller.relation.value, 4);
    expect(find.text('无法拉黑'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('关注菜单选择后仍持有在途锁直到远端写入完成', (tester) async {
    await mount(tester);
    late Future<void> pending;
    await tester.runAsync(() async {
      pending = controller.onFollow(context);
      await interceptor.waitForRequests(1);
    });
    await resolve(tester, 0, {
      'code': 0,
      'data': {'tag': [], 'special': 0},
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消关注'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await interceptor.waitForRequests(2);
      await controller.onRemoveFan();
    });
    expect(requests, hasLength(2));
    await resolve(tester, 1, {'code': 0});
    await tester.runAsync(() => pending);
    expect(controller.relation.value, 0);
    await finish(tester);
  });

  testWidgets('同UID换凭据重查空间并清空旧关系，关闭后解除订阅', (tester) async {
    await mount(tester);
    await tester.runAsync(() async {
      controller.onInit();
      await interceptor.waitForRequests(1);
      Accounts.replaceCredentials(login('new'));
      await interceptor.waitForRequests(2);
    });
    expect(controller.loadingState.value, isA<Loading>());
    expect(controller.relation.value, 0);
    expect(controller.isFollowed, isNull);
    expect(requests[1].options.extra['account'], same(Accounts.main));
    await resolve(tester, 1, {
      'code': 0,
      'data': {'relation': 2},
    });
    await resolve(tester, 0, {
      'code': 0,
      'data': {'relation': -1},
    });
    expect(controller.relation.value, 2);
    controller.onDelete();
    Accounts.replaceCredentials(login('latest'));
    expect(requests, hasLength(2));
    await finish(tester);
  });

  testWidgets('领取经验固定账号、重复合并，切号后不显示旧成功', (tester) async {
    await mount(tester);
    controller.mid = 1;
    late Future<void> pending;
    await tester.runAsync(() async {
      pending = controller.vipExpAdd();
      await controller.vipExpAdd();
      await interceptor.waitForRequests(1);
    });
    expect(requests, hasLength(1));
    expect(requests.single.options.queryParameters['csrf'], 'old');
    Accounts.accountMode[AccountType.main.index] = login('new');
    await resolve(tester, 0, {'code': 0});
    await tester.runAsync(() => pending);
    await tester.pumpAndSettle();
    expect(find.text('领取成功'), findsNothing);
    await finish(tester);
  });
  test('旧菜单回调在账号替换后不调用新账号写入', () async {
    var called = false;
    final action = controller.scopedAction(() async => called = true);
    Accounts.accountMode[AccountType.main.index] = login('new');
    await action();
    expect(called, isFalse);
  });
}
