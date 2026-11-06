import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/request_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <Completer<ResponseBody>>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) {
    final result = Completer<ResponseBody>();
    requests.add(result);
    return result.future;
  }

  void json(int index, Object value) => requests[index].complete(
    ResponseBody.fromString(
      jsonEncode(value),
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
  late List<Account> previousAccounts;
  setUpAll(() async {
    GStorage.setting = await Hive.openBox(
      'history-status-setting',
      bytes: Uint8List(0),
    );
    GStorage.video = await Hive.openBox(
      'history-status-video',
      bytes: Uint8List(0),
    );
    GStorage.localCache = await Hive.openBox(
      'history-status-cache',
      bytes: Uint8List(0),
    );
    previousAccounts = List<Account>.of(Accounts.accountMode);
    Request();
    Request.dio.interceptors.clear();
  });
  setUp(() {
    adapter = _Adapter();
    Request.dio.httpClientAdapter = adapter;
  });
  tearDown(() {
    Accounts.accountMode.setAll(0, previousAccounts);
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await Hive.close();
  });
  Future<void> dispatched(int count) async {
    for (var i = 0; i < 1000 && adapter.requests.length < count; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(adapter.requests.length, count);
  }

  Account account(int mid) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': 'synthetic'}),
    null,
    null,
  );

  test(
    'AUDIT2: old account response cannot replace current history pause',
    () async {
      Accounts.accountMode[AccountType.heartbeat.index] = account(123);
      final old = RequestUtils.syncHistoryStatus();
      await dispatched(1);
      Accounts.accountMode[AccountType.heartbeat.index] = account(456);
      final latest = RequestUtils.syncHistoryStatus();
      await dispatched(2);
      adapter.json(1, {'code': 0, 'data': true});
      await latest;
      expect(Pref.historyPause, isTrue);
      adapter.json(0, {'code': 0, 'data': false});
      await old;
      expect(Pref.historyPause, isTrue);
    },
  );
}
