import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/grpc/bilibili/pagination.pb.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/grpc/bilibili/app/listener/v1.pb.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/pages/audio/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_http_adapter.dart';

class _Adapter extends ControlledHttpAdapter {
  void playlist(int index, List<int> ids, {String? prev, String? next}) =>
      pending[index].complete(
        ResponseBody.fromBytes(
          GrpcReq.compressProtobuf(
            PlaylistResp(
              list: ids.map(
                (id) => DetailItem(
                  item: PlayItem(
                    oid: Int64(id),
                    subId: [Int64(id)],
                    itemType: 2,
                  ),
                ),
              ),
              reachStart: prev == null,
              reachEnd: next == null,
              paginationReply: PaginationReply(prev: prev, next: next),
            ).writeToBuffer(),
          ),
          200,
          headers: {
            'grpc-status': ['0'],
            'content-type': ['application/grpc'],
          },
        ),
      );

  void malformed(int index) => pending[index].complete(
    ResponseBody.fromBytes(
      [0],
      200,
      headers: {
        'grpc-status': ['0'],
        'content-type': ['application/grpc'],
      },
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Adapter adapter;
  late List<Account> previousAccounts;
  late AudioController controller;
  var closed = false;
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
    controller = AudioController()
      ..id = Int64(11)
      ..oid = Int64(11)
      ..subId = [Int64(11)]
      ..itemType = 2
      ..from = PlaylistSource.DEFAULT;
    controller.animController = AnimationController(
      vsync: controller,
      duration: const Duration(milliseconds: 200),
    );
    closed = false;
  });
  tearDown(() {
    if (!closed) controller.onClose();
    adapter.close();
    Accounts.accountMode.setAll(0, previousAccounts);
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await Hive.close();
  });

  Future<void> initialize({String? prev, String? next}) async {
    final operation = controller.reloadPlaylist();
    await adapter.waitForRequests(1);
    adapter.playlist(0, [11, 22], prev: prev, next: next);
    expect(await operation, isTrue);
  }

  test('playlist order keeps the most recent selection', () async {
    final first = controller.onChangeOrder(ListOrder.ORDER_REVERSE);
    await adapter.waitForRequests(1);
    final second = controller.onChangeOrder(ListOrder.ORDER_NORMAL);
    await adapter.waitForRequests(2);
    adapter.playlist(1, [11, 22]);
    expect(await second, isTrue);
    adapter.playlist(0, [22, 11]);
    expect(await first, isFalse);
    expect(controller.order, ListOrder.ORDER_NORMAL);
    expect(controller.playlist!.map((e) => e.item.oid.toInt()), [11, 22]);
  });

  test(
    'pagination is serial and overlapping pages preserve selection',
    () async {
      await initialize(prev: 'prev', next: 'next');
      final next = controller.loadNext();
      expect(await controller.loadNext(), isFalse);
      expect(await controller.loadPrev(), isFalse);
      await adapter.waitForRequests(2);
      adapter.playlist(1, [22, 33, 33], next: 'next2');
      expect(await next, isTrue);
      expect(controller.playlist!.map((e) => e.item.oid.toInt()), [11, 22, 33]);
      final prev = controller.loadPrev();
      await adapter.waitForRequests(3);
      adapter.playlist(2, [1, 11], prev: 'prev2');
      expect(await prev, isTrue);
      expect(controller.playlist!.map((e) => e.item.oid.toInt()), [
        1,
        11,
        22,
        33,
      ]);
      expect(controller.index, 1);
      expect(controller.audioItem.value!.item.oid, Int64(11));
    },
  );

  test('failed page retains content and cursor until explicit retry', () async {
    await initialize(next: 'next');
    final operation = controller.loadNext();
    await adapter.waitForRequests(2);
    adapter.malformed(1);
    expect(await operation, isFalse);
    expect(controller.playlistPageState.value, isA<Error>());
    expect(controller.playlist!.length, 2);
    expect(await controller.loadNext(), isFalse);
    expect(adapter.requests.length, 2);
    final retry = controller.retryPlaylistPage();
    await adapter.waitForRequests(3);
    final request = PlaylistReq.fromBuffer(
      GrpcReq.decompressProtobuf(adapter.requests[2].data),
    );
    expect(request.pagination.next, 'next');
    adapter.playlist(2, [33]);
    expect(await retry, isTrue);
    expect(controller.playlist!.length, 3);
  });

  test(
    'sorting invalidates an older page and immediately permits a new query',
    () async {
      await initialize(next: 'next');
      final page = controller.loadNext();
      await adapter.waitForRequests(2);
      final refresh = controller.onChangeOrder(ListOrder.ORDER_REVERSE);
      await adapter.waitForRequests(3);
      adapter.playlist(2, [22, 11]);
      expect(await refresh, isTrue);
      adapter.playlist(1, [33]);
      expect(await page, isFalse);
      expect(controller.playlist!.map((e) => e.item.oid.toInt()), [22, 11]);
      expect(controller.index, 1);
    },
  );

  test('account replacement hides old list and rejects late results', () async {
    await initialize(next: 'next');
    final oldPage = controller.loadNext();
    await adapter.waitForRequests(2);
    Accounts.accountMode[AccountType.main.index] = const NoAccount();
    final changes = Accounts.mainChanges as ValueNotifier<int>;
    changes.value++;
    expect(controller.playlist, isNull);
    expect(controller.index, isNull);
    expect(controller.playlistState.value, isA<Loading>());
    await adapter.waitForRequests(3);
    adapter.playlist(1, [33]);
    expect(await oldPage, isFalse);
    adapter.playlist(2, [11, 44]);
    for (var i = 0; i < 20 && controller.playlist == null; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.playlist!.map((e) => e.item.oid.toInt()), [11, 44]);
  });

  test('initialization failure permits same-order retry and valid missing-anchor or empty lists', () async {
    final first = controller.onChangeOrder(ListOrder.ORDER_REVERSE);
    await adapter.waitForRequests(1);
    adapter.malformed(0);
    expect(await first, isFalse);
    expect(controller.playlistState.value, isA<Error>());
    final retry = controller.onChangeOrder(ListOrder.ORDER_REVERSE);
    await adapter.waitForRequests(2);
    adapter.playlist(1, [22, 33]);
    expect(await retry, isTrue);
    expect(controller.playlist!.length, 2);
    expect(controller.index, isNull);
    expect(controller.oid, Int64(11));
    expect(controller.audioItem.value, isNull);
    final empty = controller.reloadPlaylist();
    await adapter.waitForRequests(3);
    adapter.playlist(2, []);
    expect(await empty, isTrue);
    expect(controller.playlist, isEmpty);
  });

  test('removed entries stay removed across overlapping pages and repeated cursor stops', () async {
    await initialize(next: 'next');
    controller.removePlaylistItem(controller.playlist!.last);
    final operation = controller.loadNext();
    await adapter.waitForRequests(2);
    adapter.playlist(1, [11, 22], next: 'next');
    expect(await operation, isTrue);
    expect(controller.playlist!.map((e) => e.item.oid.toInt()), [11]);
    expect(await controller.loadNext(), isFalse);
    expect(adapter.requests.length, 2);
  });

  test('selection changed during initialization is not overwritten by its old anchor', () async {
    final operation = controller.reloadPlaylist();
    await adapter.waitForRequests(1);
    controller
      ..oid = Int64(22)
      ..subId = [Int64(22)];
    adapter.playlist(0, [11, 22]);
    expect(await operation, isTrue);
    expect(controller.index, 1);
    expect(controller.audioItem.value, isNull);
  });

  test('closed controller rejects in-flight initialization', () async {
    final operation = controller.reloadPlaylist();
    await adapter.waitForRequests(1);
    controller.onClose();
    closed = true;
    adapter.playlist(0, [11, 22]);
    expect(await operation, isFalse);
    expect(controller.playlist, isNull);
  });
  test(
    'row actions do not target equal entries from a newer playlist snapshot',
    () async {
      await initialize();
      final oldItem = controller.playlist!.last;
      final operation = controller.reloadPlaylist();
      await adapter.waitForRequests(2);
      adapter.playlist(1, [11, 22]);
      expect(await operation, isTrue);
      controller.removePlaylistItem(oldItem);
      await controller.selectPlaylistItem(oldItem);
      expect(controller.playlist!.length, 2);
      expect(adapter.requests.length, 2);
    },
  );
}
