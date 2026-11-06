import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/home_tab_type.dart';
import 'package:pili_aurora/models/user/info.dart';
import 'package:pili_aurora/pages/pgc/controller.dart';
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

  Account account(int mid) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': 'synthetic'}),
    null,
    null,
  );

  test('FINAL: PGC follows do not retain an old account response', () async {
    Accounts.accountMode[AccountType.main.index] = account(123);
    final controller = PgcController(tabType: HomeTabType.bangumi);
    addTearDown(controller.onClose);
    final first = controller.queryPgcFollow();
    await flush();
    expect(adapter.pending, hasLength(1));
    Accounts.accountMode[AccountType.main.index] = account(456);
    controller.onChangeAccount(true);
    await flush();
    adapter.json(0, {
      'code': 0,
      'data': {
        'total': 1,
        'list': [
          {'season_id': 123, 'title': 'account-A-only'},
        ],
      },
    });
    await first;
    await flush();
    expect(adapter.pending, hasLength(2));
    expect(controller.followLoading, isTrue);
    adapter.json(1, {
      'code': 0,
      'data': {
        'total': 1,
        'list': [
          {'season_id': 456, 'title': 'account-B'},
        ],
      },
    });
    await flush();
    expect(controller.followLoading, isFalse);
    expect(controller.followState.value.dataOrNull?.single.seasonId, 456);
    // 旧请求不能成为账号 B 的当前订阅快照。
    expect(
      controller.followState.value.dataOrNull?.any((e) => e.seasonId == 123) ??
          false,
      isFalse,
    );
  });
}
