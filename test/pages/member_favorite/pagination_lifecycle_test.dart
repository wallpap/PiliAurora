import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
}
