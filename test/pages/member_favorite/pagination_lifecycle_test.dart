import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
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

class _Adapter implements HttpClientAdapter {
  final pending = <Completer<ResponseBody>>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? s,
    Future<void>? c,
  ) {
    final reply = Completer<ResponseBody>();
    pending.add(reply);
    return reply.future;
  }

  void json(int i, Object data) => pending[i].complete(
    ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    ),
  );
  @override
  void close({bool force = false}) {}
}

class _ControlledController extends MemberFavoriteCtr {
  _ControlledController() : super(mid: 123);
  final response = Completer<LoadingState<List<SpaceFavData>?>>();
  @override
  Future<LoadingState<List<SpaceFavData>?>> customGetData() => response.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Adapter adapter;
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
    adapter = _Adapter();
    Request.dio.httpClientAdapter = adapter;
    Get.put(AccountService()).isLogin.value = true;
  });
  tearDown(() {
    Accounts.accountMode.setAll(0, originals);
    Get.reset();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await Hive.close();
  });
  Future<void> flush() async {
    for (var i = 0; i < 24; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('FINAL: member favorites load each page once', () async {
    final controller = MemberFavoriteCtr(mid: 123);
    addTearDown(controller.onClose);
    controller.favState.value = SpaceFavData.fromJson({
      'mediaListResponse': {
        'count': 5,
        'list': [
          {'id': 11},
        ],
      },
    });
    controller.favEnd.value = false;
    final first = controller.userFavFolder();
    final second = controller.userFavFolder();
    await flush();
    expect(adapter.pending, hasLength(1));
    for (var i = 0; i < 1; i++) {
      adapter.json(i, {
        'code': 0,
        'data': {
          'has_more': true,
          'list': [
            {'id': 22},
          ],
        },
      });
    }
    await Future.wait([first, second]);
    expect(
      controller.favState.value.mediaListResponse!.list!.map((e) => e.id),
      [11, 22],
    );
    expect(controller.favPage, 3);
  });
  test('FINAL: 成员订阅同一页仅请求一次', () async {
    final controller = MemberFavoriteCtr(mid: 123);
    addTearDown(controller.onClose);
    controller.subState.value = SpaceFavData.fromJson({
      'mediaListResponse': {
        'count': 5,
        'list': [
          {'id': 11},
        ],
      },
    });
    controller.subEnd.value = false;
    final first = controller.userSubFolder();
    final second = controller.userSubFolder();
    await flush();
    expect(adapter.pending, hasLength(1));
    for (var i = 0; i < 1; i++) {
      adapter.json(i, {
        'code': 0,
        'data': {
          'has_more': true,
          'list': [
            {'id': 22},
          ],
        },
      });
    }
    await Future.wait([first, second]);
    expect(
      controller.subState.value.mediaListResponse!.list!.map((e) => e.id),
      [11, 22],
    );
    expect(controller.subPage, 3);
  });
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
    await flush();
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
    await flush();
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
