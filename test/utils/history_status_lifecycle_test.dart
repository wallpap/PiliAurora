import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/request_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

import '../support/controlled_http_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ControlledHttpAdapter adapter;
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
    adapter = ControlledHttpAdapter();
    Request.dio.httpClientAdapter = adapter;
  });
  tearDown(() {
    adapter.close();
    Accounts.accountMode.setAll(0, previousAccounts);
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await Hive.close();
  });

  Account account(int mid) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': 'synthetic'}),
    null,
    null,
  );

  test(
    'old account response cannot replace current history pause',
    () async {
      Accounts.accountMode[AccountType.heartbeat.index] = account(123);
      final old = RequestUtils.syncHistoryStatus();
      await adapter.waitForRequests(1);
      Accounts.accountMode[AccountType.heartbeat.index] = account(456);
      final latest = RequestUtils.syncHistoryStatus();
      await adapter.waitForRequests(2);
      adapter.json(1, {'code': 0, 'data': true});
      await latest;
      expect(Pref.historyPause, isTrue);
      adapter.json(0, {'code': 0, 'data': false});
      await old;
      expect(Pref.historyPause, isTrue);
    },
  );
}
