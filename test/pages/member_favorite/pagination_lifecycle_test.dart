import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/member_favorites.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/user/info.dart';
import 'package:pili_aurora/pages/member_favorite/controller.dart';
import 'package:pili_aurora/models/remote/space/space_fav/data.dart';
import 'package:pili_aurora/services/account_service.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_http_adapter.dart';

class _ControlledController extends MemberFavoriteCtr {
  _ControlledController() : super(mid: 123);
  final response = Completer<LoadingState<List<SpaceFavData>?>>();
  @override
  Future<LoadingState<List<SpaceFavData>?>> customGetData() => response.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ControlledHttpAdapter adapter;
  late List<Account> originals;
  setUpAll(() async {
    GStorage.setting = await Hive.openBox(
      'final-audit-settings',
      bytes: Uint8List(0),
    );
    GStorage.video = await Hive.openBox(
      'final-audit-video',
      bytes: Uint8List(0),
    );
    GStorage.localCache = await Hive.openBox(
      'final-audit-cache',
      bytes: Uint8List(0),
    );
    GStorage.userInfo = await Hive.openBox<UserInfoData>(
      'final-audit-user',
      bytes: Uint8List(0),
    );
    originals = List.of(Accounts.accountMode);
    Request();
    Request.dio.interceptors.clear();
    Get.testMode = true;
  });
  setUp(() {
    adapter = ControlledHttpAdapter();
    Request.dio.httpClientAdapter = adapter;
    Get.put(AccountService()).isLogin.value = true;
  });
  tearDown(() {
    adapter.close();
    Accounts.accountMode.setAll(0, originals);
    Get.reset();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await Hive.close();
  });

  for (final subscribed in [false, true]) {
    test('成员${subscribed ? '订阅' : '收藏'}同一页只请求一次并正确推进', () async {
      final controller = MemberFavoriteCtr(mid: 123);
      addTearDown(controller.onClose);
      final state = subscribed ? controller.subState : controller.favState;
      final end = subscribed ? controller.subEnd : controller.favEnd;
      final load = subscribed
          ? controller.userSubFolder
          : controller.userFavFolder;
      state.value = SpaceFavData.fromJson({
        'mediaListResponse': {
          'count': 5,
          'list': [
            {'id': 11},
          ],
        },
      });
      end.value = false;
      final first = load();
      final second = load();
      await adapter.waitForRequests(1);
      expect(adapter.pending, hasLength(1));
      adapter.json(0, {
        'code': 0,
        'data': {
          'has_more': true,
          'list': [
            {'id': 22},
          ],
        },
      });
      await Future.wait([first, second]);
      expect(state.value.mediaListResponse!.list!.map((e) => e.id), [11, 22]);
      expect(subscribed ? controller.subPage : controller.favPage, 3);
    });
  }
  test('刷新使旧分页失效并恢复新列表的分页', () async {
    final controller = _ControlledController();
    addTearDown(controller.onClose);
    SpaceFavData snapshot(int id) => SpaceFavData.fromJson({
      'mediaListResponse': {
        'count': 5,
        'list': [
          {'id': id},
        ],
      },
    });
    controller.favState.value = snapshot(11);
    controller.favEnd.value = false;
    final old = controller.userFavFolder();
    await adapter.waitForRequests(1);
    final refresh = controller.onRefresh();
    controller.response.complete(Success([snapshot(33), snapshot(44)]));
    await refresh;
    adapter.json(0, {
      'code': 0,
      'data': {
        'has_more': true,
        'list': [
          {'id': 22},
        ],
      },
    });
    await old;
    expect(
      controller.favState.value.mediaListResponse!.list!.map((e) => e.id),
      [33],
    );
    expect(controller.favPage, 2);
    final next = controller.userFavFolder();
    await adapter.waitForRequests(2);
    adapter.json(1, {
      'code': 0,
      'data': {
        'has_more': false,
        'list': [
          {'id': 55},
        ],
      },
    });
    await next;
    expect(
      controller.favState.value.mediaListResponse!.list!.map((e) => e.id),
      [33, 55],
    );
    expect(controller.favPage, 3);
  });
  test('不完整首屏显式失败且不开放旧分区分页', () async {
    final controller = _ControlledController();
    addTearDown(controller.onClose);
    final pending = controller.onRefresh();
    controller.response.complete(Success([SpaceFavData()]));
    await pending;
    expect(controller.loadingState.value, isA<Error>());
    controller.favEnd.value = false;
    await controller.userFavFolder();
    expect(adapter.pending, isEmpty);
  });

  test('账号替换使旧分页结果失效且请求固定原账号', () async {
    final controller = MemberFavoriteCtr(mid: 123);
    addTearDown(controller.onClose);
    final original = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '123', 'bili_jct': 'old'}),
      null,
      null,
    );
    Accounts.accountMode[AccountType.main.index] = original;
    controller.favState.value = SpaceFavData.fromJson({
      'mediaListResponse': {
        'count': 5,
        'list': [
          {'id': 11},
        ],
      },
    });
    controller.favEnd.value = false;
    final pending = controller.userFavFolder();
    await adapter.waitForRequests(1);
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    adapter.json(0, {
      'code': 0,
      'data': {
        'has_more': false,
        'list': [
          {'id': 22},
        ],
      },
    });
    await pending;
    expect(adapter.requests.single.extra['account'], same(original));
    expect(controller.favPage, 2);
    expect(controller.favState.value.mediaListResponse!.list!.single.id, 11);
  });

  for (final subscribed in [false, true]) {
    testWidgets('成员${subscribed ? '订阅' : '收藏'}解析失败保留列表和页码后可重试', (tester) async {
      await tester.pumpWidget(
        GetMaterialApp(
          builder: FlutterSmartDialog.init(),
          home: const Scaffold(),
        ),
      );
      final controller = MemberFavoriteCtr(mid: 123);
      addTearDown(controller.onClose);
      final state = subscribed ? controller.subState : controller.favState;
      final end = subscribed ? controller.subEnd : controller.favEnd;
      final load = subscribed
          ? controller.userSubFolder
          : controller.userFavFolder;
      state.value = SpaceFavData.fromJson({
        'mediaListResponse': {
          'count': 5,
          'list': [
            {'id': 11},
          ],
        },
      });
      end.value = false;
      await tester.runAsync(() async {
        final pending = load();
        await adapter.waitForRequests(1);
        adapter.json(0, {
          'code': 0,
          'data': {'has_more': true},
        });
        await pending;
      });
      expect(subscribed ? controller.subPage : controller.favPage, 2);
      expect(state.value.mediaListResponse!.list!.single.id, 11);
      expect(end.value, false);
      await tester.runAsync(() async {
        final pending = load();
        await adapter.waitForRequests(2);
        adapter.json(1, {
          'code': 0,
          'data': {
            'has_more': false,
            'list': [
              {'id': 22},
              {'id': 22},
            ],
          },
        });
        await pending;
      });
      expect(state.value.mediaListResponse!.list!.map((item) => item.id), [
        11,
        22,
      ]);
      expect(end.value, true);
      final dismissed = SmartDialog.dismiss(status: SmartStatus.allToast);
      await tester.pumpAndSettle();
      await dismissed;
      await tester.pumpWidget(const SizedBox());
    });

    test('成员${subscribed ? '订阅' : '收藏'}无内容终页可空，缺分页证据不能当成功', () async {
      Future<LoadingState<MemberFavoritePage>> load() =>
          MemberFavoritesHttp.folders(
            account: Accounts.main,
            mid: 123,
            page: 2,
            subscribed: subscribed,
          );
      var pending = load();
      await adapter.waitForRequests(1);
      adapter.json(0, {
        'code': 0,
        'data': {'has_more': false, 'list': null},
      });
      expect((await pending).data.items, isEmpty);
      pending = load();
      await adapter.waitForRequests(2);
      adapter.json(1, {
        'code': 0,
        'data': {'list': []},
      });
      expect(await pending, isA<Error>());
    });
  }
  test('刷新后的旧收藏夹删除回调不能修改新分区或触发额外刷新', () async {
    final controller = _ControlledController();
    addTearDown(controller.onClose);
    controller.favState.value = SpaceFavData.fromJson({
      'mediaListResponse': {
        'count': 1,
        'list': [
          {'id': 11},
        ],
      },
    });
    final deleted = controller.folderDeletionAction(
      false,
      controller.favState.value.mediaListResponse!.list!.single,
    );
    final pending = controller.onRefresh();
    controller.response.complete(
      Success([
        SpaceFavData.fromJson({
          'mediaListResponse': {
            'count': 1,
            'list': [
              {'id': 11},
            ],
          },
        }),
        SpaceFavData.fromJson({
          'mediaListResponse': {'count': 0, 'list': []},
        }),
      ]),
    );
    await pending;
    deleted(true);
    expect(controller.favState.value.mediaListResponse!.list!.single.id, 11);
    expect(adapter.pending, isEmpty);
  });
  test('同UID换凭据立即隐藏旧分区并重新请求，关闭后释放账号订阅', () async {
    LoginAccount login(String csrf) => LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '123', 'bili_jct': csrf}),
      null,
      null,
    );
    Accounts.accountMode[AccountType.main.index] = login('old');
    final controller = MemberFavoriteCtr(mid: 123)..onInit();
    await adapter.waitForRequests(1);
    final next = login('new');
    Accounts.replaceCredentials(next);
    expect(controller.loadingState.value, isA<Loading>());
    await adapter.waitForRequests(2);
    final applied = controller.loadingState.stream.firstWhere(
      (s) => s is Success,
    );
    adapter.json(1, {
      'code': 0,
      'data': [
        {
          'mediaListResponse': {
            'count': 1,
            'list': [
              {'id': 33},
            ],
          },
        },
        {
          'mediaListResponse': {'count': 0, 'list': []},
        },
      ],
    });
    await applied;
    expect(adapter.requests[1].extra['account'], same(next));
    expect(controller.favState.value.mediaListResponse!.list!.single.id, 33);
    controller.onClose();
    Accounts.replaceCredentials(login('latest'));
    expect(adapter.requests, hasLength(2));
    adapter.json(0, {'code': 0, 'data': []});
  });
}
