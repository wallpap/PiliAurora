import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/fav/fav_pgc/list.dart';
import 'package:pili_aurora/models/remote/pgc/season_follow_status.dart';
import 'package:pili_aurora/pages/fav/pgc/controller.dart';
import 'package:pili_aurora/pages/video/introduction/pgc/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _Intro extends PgcIntroController {
  int target = 1;
  @override
  int get followSeasonId => target;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  final controllers = <GetxController>[];
  LoginAccount account(int id) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$id', 'bili_jct': 'fixture-$id'}),
    null,
    null,
  );
  late Account original;
  T own<T extends GetxController>(T controller) {
    controllers.add(controller);
    return controller;
  }

  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    GStorage.userInfo = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() {
    original = account(1);
    Accounts.accountMode[AccountType.main.index] = original;
    requests.clear();
  });
  tearDown(() {
    for (final controller in controllers) {
      controller.onDelete();
    }
    controllers.clear();
    Get.reset();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    GetMaterialApp(
      builder: FlutterSmartDialog.init(),
      home: const Scaffold(),
    ),
  );
  Future<void> finish(WidgetTester tester) async {
    final dismissed = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismissed;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  test('追番状态失败可重试，未关注不要求分组，切号和换目标拒绝迟到结果', () async {
    final controller = own(_Intro());
    var pending = controller.queryIsFollowed();
    await interceptor.waitForRequests(1);
    requests[0].reply.complete({'code': -403, 'message': '拒绝查询'});
    await pending;
    expect(controller.followState.value, isA<Error>());
    pending = controller.queryIsFollowed();
    await interceptor.waitForRequests(2);
    requests[1].reply.complete({
      'code': 0,
      'result': {'follow': 0},
    });
    await pending;
    expect(controller.followState.value.data.followed, isFalse);
    expect(controller.followState.value.data.status, isNull);
    pending = controller.queryIsFollowed();
    await interceptor.waitForRequests(3);
    controller.target = 2;
    Accounts.accountMode[AccountType.main.index] = account(2);
    requests[2].reply.complete({
      'code': 0,
      'result': {'follow': 1, 'follow_status': 3},
    });
    await pending;
    expect(controller.followState.value, isA<Loading>());
    expect(requests[2].options.extra['account'], same(original));
  });

  testWidgets('追番写入互斥，确认成功淘汰早先查询，失败保留已确认状态', (tester) async {
    await mount(tester);
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    final controller = own(_Intro());
    await tester.runAsync(() async {
      final reading = controller.queryIsFollowed();
      await interceptor.waitForRequests(1);
      final writing = controller.pgcAdd();
      await interceptor.waitForRequests(2);
      await controller.pgcAdd();
      expect(requests, hasLength(2));
      expect(controller.followBusy.value, isTrue);
      requests[1].reply.complete({'code': 0});
      await writing;
      requests[0].reply.complete({
        'code': 0,
        'result': {'follow': 0},
      });
      await reading;
      expect(controller.followState.value.data.followed, isTrue);
      final deleting = controller.pgcDel();
      await interceptor.waitForRequests(3);
      requests[2].reply.complete({'code': -403, 'message': '拒绝取消'});
      await deleting;
    });
    expect(controller.followState.value.data.followed, isTrue);
    expect(controller.followBusy.value, isFalse);
    await finish(tester);
  });

  testWidgets('追番管理拒绝重叠批量写入，失败保留选择，成功保留后来新增选择', (tester) async {
    await mount(tester);
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    final controller = own(FavPgcController(1, 2));
    final first = FavPgcItemModel(seasonId: 1)..checked = true;
    final second = FavPgcItemModel(seasonId: 2);
    controller.loadingState.value = Success([first, second]);
    controller.rxCount.value = 1;
    controller.enableMultiSelect.value = true;
    await tester.runAsync(() async {
      final failed = controller.onUpdateList(3);
      await interceptor.waitForRequests(1);
      await controller.pgcDel(1);
      expect(requests, hasLength(1));
      requests[0].reply.complete({'code': -403, 'message': '拒绝迁移'});
      await failed;
      expect(controller.checkedCount, 1);
      expect(first.checked, isTrue);
      final confirmed = controller.onUpdateList(3);
      await interceptor.waitForRequests(2);
      controller.onSelect(second);
      requests[1].reply.complete({'code': 0});
      await confirmed;
    });
    expect(controller.loadingState.value.data, [second]);
    expect(controller.checkedCount, 1);
    expect(second.checked, isTrue);
    expect(controller.pendingIds, isEmpty);
    expect(controller.page, 1);
    await tester.runAsync(() async {
      final more = controller.onLoadMore();
      await interceptor.waitForRequests(3);
      expect(requests[2].options.queryParameters['pn'], 1);
      requests[2].reply.complete({
        'code': 0,
        'data': {
          'list': [
            {'season_id': 2},
            {'season_id': 3},
          ],
        },
      });
      await interceptor.waitForRequests(4);
      requests[3].reply.complete({
        'code': 0,
        'data': {
          'list': [
            {'season_id': 4},
          ],
        },
      });
      await more;
    });
    expect(controller.loadingState.value.data!.map((item) => item.seasonId), [
      2,
      3,
      4,
    ]);
    expect(second.checked, isTrue);
    await finish(tester);
  });

  test('追番管理刷新或切号后不删除新列表，分页重读按身份去重', () async {
    final controller = own(FavPgcController(1, 2));
    final old = FavPgcItemModel(seasonId: 1);
    controller.loadingState.value = Success([old]);
    final pending = controller.pgcDel(1);
    await interceptor.waitForRequests(1);
    final replacement = FavPgcItemModel(seasonId: 1);
    controller.loadingState.value = Success([replacement]);
    Accounts.accountMode[AccountType.main.index] = account(2);
    requests[0].reply.complete({'code': 0});
    await pending;
    expect(controller.loadingState.value.data, [replacement]);
    final next = FavPgcItemModel(seasonId: 2);
    expect(controller.filterList([replacement, next], false), [next]);
    expect(requests.single.options.extra['account'], same(original));
  });

  testWidgets('追番切号后的迟到写入成功不改变当前状态', (tester) async {
    await mount(tester);
    final controller = own(_Intro());
    controller.followState.value = const Success(
      SeasonFollowStatus(followed: false),
    );
    await tester.runAsync(() async {
      final pending = controller.pgcAdd();
      await interceptor.waitForRequests(1);
      Accounts.accountMode[AccountType.main.index] = account(2);
      requests[0].reply.complete({'code': 0});
      await pending;
    });
    expect(controller.followState.value.data.followed, isFalse);
    expect(controller.followBusy.value, isFalse);
    await finish(tester);
  });
}
