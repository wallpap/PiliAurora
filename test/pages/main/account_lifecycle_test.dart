import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/grpc/bilibili/app/dynamic/v1.pb.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/user/info.dart';
import 'package:pili_aurora/pages/main/controller.dart';
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
  void red(int i, int count) => pending[i].complete(
    ResponseBody.fromBytes(
      GrpcReq.compressProtobuf(
        DynRedReply(dynRedItem: DynRedItem(count: Int64(count)))
            .writeToBuffer(),
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
  late List<Account> originals;
  late AccountService service;
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
    service = Get.put(AccountService())..isLogin.value = true;
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

  test(
    'FINAL: logout invalidates an outstanding dynamic badge query',
    () async {
      final controller = MainController()
        ..hasDyn = true
        ..getUnreadDynamic();
      await flush();
      expect(adapter.pending, hasLength(1));
      service.isLogin.value = false;
      controller.onChangeAccount(false);
      expect(controller.dynCount.value, 0);
      adapter.red(0, 7);
      await flush();
      expect(controller.dynCount.value, 0);
    },
  );
  test('主动清除角标使在途查询失效', () async {
    final controller = MainController()
      ..hasDyn = true
      ..getUnreadDynamic();
    await flush();
    controller.setDynCount();
    adapter.red(0, 7);
    await flush();
    expect(controller.dynCount.value, 0);
    controller.getUnreadDynamic();
    await flush();
    adapter.red(1, 3);
    await flush();
    expect(controller.dynCount.value, 3);
  });
}
