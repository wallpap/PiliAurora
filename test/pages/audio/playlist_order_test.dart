import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/grpc/bilibili/app/listener/v1.pb.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/audio/controller.dart';
import 'package:pili_aurora/services/settings/settings_backup.dart';
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
  void playlist(int index, List<int> ids) => requests[index].complete(
    ResponseBody.fromBytes(
      GrpcReq.compressProtobuf(
        PlaylistResp(
          list: ids.map(
            (id) => DetailItem(item: PlayItem(oid: Int64(id), itemType: 2)),
          ),
          reachStart: true,
          reachEnd: true,
        ).writeToBuffer(),
      ),
      200,
      headers: {
        'grpc-status': ['0'],
        'content-type': ['application/grpc'],
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
      'audit-round2-setting',
      bytes: Uint8List(0),
    );
    GStorage.video = await Hive.openBox(
      'audit-round2-video',
      bytes: Uint8List(0),
    );
    GStorage.localCache = await Hive.openBox(
      'audit-round2-cache',
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

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Account account(int mid) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': 'synthetic'}),
    null,
    null,
  );

  test('AUDIT2: playlist order keeps the most recent selection', () async {
    final controller = AudioController()
      ..id = Int64(11)
      ..oid = Int64(11)
      ..subId = [Int64(11)]
      ..itemType = 2
      ..from = PlaylistSource.DEFAULT;
    controller.onChangeOrder(ListOrder.ORDER_REVERSE);
    await dispatched(1);
    controller.onChangeOrder(ListOrder.ORDER_NORMAL);
    await dispatched(2);
    adapter.playlist(1, [11, 22]);
    await settle();
    expect(controller.playlist!.map((e) => e.item.oid.toInt()), [11, 22]);
    adapter.playlist(0, [22, 11]);
    await settle();
    expect(controller.order, ListOrder.ORDER_NORMAL);
    expect(controller.playlist!.map((e) => e.item.oid.toInt()), [11, 22]);
  });
}
