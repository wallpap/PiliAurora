import 'dart:async';

import 'package:flutter/services.dart';
import 'package:pili_aurora/utils/id_utils.dart';

import 'package:dio/dio.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/grpc/bilibili/app/listener/v1.pb.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/pages/audio/controller.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:protobuf/protobuf.dart' show GeneratedMessage;

import '../../support/controlled_http_adapter.dart';
import '../../support/memory_box.dart';

class _Stream implements PlayerStream {
  @override
  dynamic noSuchMethod(Invocation invocation) => const Stream<Never>.empty();
}

class _Player implements Player {
  final opened = <String>[];
  Completer<void>? opening;
  Object? openError;
  Completer<void>? seeking;
  @override
  final state = PlayerState();
  @override
  PlayerStream get stream => _Stream();
  @override
  void setMediaHeader({
    String? userAgent,
    String? referer,
    Map<String, String>? headers,
  }) {}
  @override
  Future<void> open(
    Playable playable, {
    bool play = true,
    bool synchronized = true,
    void Function()? onLoadSubmitted,
  }) async {
    opened.add((playable as Media).uri);
    await opening?.future;
    if (openError case final error?) throw error;
  }

  @override
  Future<void> dispose({bool synchronized = true}) async {}
  @override
  Future<void> seek(
    Duration position, {
    bool synchronized = true,
    int? observationId,
  }) async {
    await seeking?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Adapter extends ControlledHttpAdapter {
  void reply(int index, GeneratedMessage response) => pending[index].complete(
    ResponseBody.fromBytes(
      GrpcReq.compressProtobuf(response.writeToBuffer()),
      200,
      headers: {
        'grpc-status': ['0'],
        'content-type': ['application/grpc'],
      },
    ),
  );
}

PlayURLResp _source([String? url]) => PlayURLResp(
  playerInfo: [
    MapEntry(
      Int64(1),
      PlayInfo(
        playUrl: PlayURL(
          durl: [
            ResponseUrl(
              url: url ?? 'https://media.example/audio?token=private',
            ),
          ],
        ),
      ),
    ),
  ],
);

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  final deadline = tester.binding.clock.now().add(const Duration(seconds: 3));
  while (!condition() && tester.binding.clock.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue);
}

Future<void> _complete(WidgetTester tester, Future<void> operation) async {
  var done = false;
  operation.whenComplete(() => done = true);
  await _until(tester, () => done);
  await operation;
}

void _check(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      SmartDialog.dismiss(status: SmartStatus.allToast);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 16));
      await tester.pumpAndSettle();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Adapter adapter;
  late AudioController controller;
  late Account previousAccount;
  LoginAccount account(int id) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$id', 'bili_jct': 'fixture-$id'}),
    'fixture-$id',
    null,
  );
  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>({
      SettingBoxKey.enableSponsorBlock: false,
    });
    GStorage.video = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
    Request();
    Request.dio.interceptors.clear();
  });
  setUp(() {
    previousAccount = Accounts.main;
    Accounts.accountMode[AccountType.main.index] = account(1);
    GlobalData().coins = 10;
    adapter = _Adapter();
    Request.dio.httpClientAdapter = adapter;
    controller = AudioController()
      ..oid = Int64.ONE
      ..subId = [Int64.ONE]
      ..itemType = 1;
    final item = DetailItem(item: PlayItem(oid: Int64.ONE, itemType: 1))
      ..ensureStat();
    controller.audioItem.value = item;
    controller.animController = AnimationController(
      vsync: controller,
      duration: const Duration(milliseconds: 200),
    );
  });
  tearDown(() {
    controller.onClose();
    adapter.close();
    Accounts.accountMode[AccountType.main.index] = previousAccount;
    GlobalData().coins = null;
  });
  tearDownAll(() => Request.dio.close(force: true));
  Future<void> host(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      builder: FlutterSmartDialog.init(),
      home: const Scaffold(body: SizedBox(key: ValueKey('body'))),
    ),
  );

  _check('interaction captures account and serializes overlapping writes', (
    tester,
  ) async {
    await host(tester);
    final account = Accounts.main;
    final operation = controller.actionLikeVideo();
    await _until(tester, () => adapter.requests.isNotEmpty);
    await controller.actionTriple();
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.extra['account'], same(account));
    expect(adapter.requests.single.extra['noRetry'], isTrue);
    adapter.reply(0, ThumbUpResp(message: '已点赞'));
    await _complete(tester, operation);
    expect(controller.hasLike.value, isTrue);
  });
  _check('late like cannot update a replacement item', (tester) async {
    await host(tester);
    final operation = controller.actionLikeVideo();
    await _until(tester, () => adapter.requests.isNotEmpty);
    controller
      ..audioItem.value = DetailItem()
      ..oid = Int64(2);
    adapter.reply(0, ThumbUpResp(message: '已点赞'));
    await _complete(tester, operation);
    expect(controller.hasLike.value, isFalse);
  });
  _check('late coin cannot update replacement account or its balance', (
    tester,
  ) async {
    await host(tester);
    final operation = controller.onPayCoin(1, true);
    await _until(tester, () => adapter.requests.isNotEmpty);
    Accounts.accountMode[AccountType.main.index] = account(1);
    adapter.reply(0, CoinAddResp());
    await _complete(tester, operation);
    expect(controller.coinNum.value, 0);
    expect(controller.hasLike.value, isFalse);
    expect(GlobalData().coins, 10);
  });
  _check(
    'triple honors individual acknowledgements without guessing extra coins',
    (
      tester,
    ) async {
      await host(tester);
      controller.coinNum.value = 1;
      final operation = controller.actionTriple();
      await _until(tester, () => adapter.requests.isNotEmpty);
      adapter.reply(
        0,
        TripleLikeResp(thumbOk: false, coinOk: true, favOk: true),
      );
      await _complete(tester, operation);
      expect(controller.hasLike.value, isFalse);
      expect(controller.hasFav.value, isTrue);
      expect(controller.coinNum.value, 1);
      expect(GlobalData().coins, 10);
      expect(controller.audioItem.value!.stat.favourite, 1);
    },
  );
  _check('coin confirmation stays bound to the item that opened the panel', (
    tester,
  ) async {
    await host(tester);
    final submit = controller.payCoinCallback;
    controller.oid = Int64(2);
    await submit(1, true);
    expect(adapter.requests, isEmpty);
  });
  _check(
    'unconfirmed write preserves interaction state and releases the lock',
    (tester) async {
      await host(tester);
      final first = controller.actionLikeVideo();
      await _until(tester, () => adapter.requests.isNotEmpty);
      adapter.pending[0].completeError(
        DioException(
          requestOptions: adapter.requests[0],
          type: DioExceptionType.connectionError,
          error: StateError('private-token'),
        ),
      );
      await _complete(tester, first);
      expect(controller.hasLike.value, isFalse);
      expect(adapter.requests, hasLength(1));
      final second = controller.actionLikeVideo();
      await _until(tester, () => adapter.requests.length == 2);
      adapter.reply(1, ThumbUpResp(message: '已点赞'));
      await _complete(tester, second);
      expect(controller.hasLike.value, isTrue);
    },
  );
  _check('loading a new target blocks writes using the earlier item state', (
    tester,
  ) async {
    await host(tester);
    controller.oid = Int64(2);
    await controller.actionLikeVideo();
    await controller.actionTriple();
    await controller.onPayCoin(1, true);
    expect(adapter.requests, isEmpty);
  });
  _check('favorite panel rejects a target selected after opening', (
    tester,
  ) async {
    await host(tester);
    controller.showFavBottomSheet(
      tester.element(find.byKey(const ValueKey('body'))),
    );
    await _until(tester, () => adapter.requests.isNotEmpty);
    adapter.json(0, {
      'code': 0,
      'data': {'list': []},
    });
    await tester.pump();
    controller
      ..oid = Int64(2)
      ..audioItem.value = DetailItem(
        item: PlayItem(oid: Int64(2), itemType: 1),
      );
    await controller.actionFavVideo();
    expect(adapter.requests, hasLength(1));
  });
  _check(
    'share menu keeps one item snapshot while playback selection changes',
    (tester) async {
      await host(tester);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      try {
        controller.actionShareVideo(
          tester.element(find.byKey(const ValueKey('body'))),
        );
        await tester.pumpAndSettle();
        controller
          ..oid = Int64(2)
          ..audioItem.value = DetailItem(
            item: PlayItem(oid: Int64(2), itemType: 2),
          );
        await tester.tap(find.text('复制链接'));
        await tester.pump();
        expect(copied, contains(IdUtils.av2bv(1)));
      } finally {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      }
    },
  );
  _check('account replacement blocks interaction with unrefreshed item state', (
    tester,
  ) async {
    await host(tester);
    controller
      ..id = Int64.ONE
      ..from = PlaylistSource.DEFAULT;
    final loading = controller.reloadPlaylist();
    await _until(tester, () => adapter.requests.isNotEmpty);
    adapter.reply(0, PlaylistResp(list: [controller.audioItem.value!]));
    var done = false;
    loading.then((_) => done = true);
    await _until(tester, () => done);
    expect(await loading, isTrue);
    Accounts.accountMode[AccountType.main.index] = account(1);
    await controller.actionLikeVideo();
    expect(adapter.requests, hasLength(1));
  });
  _check('empty subparts preserve the protocol empty target', (tester) async {
    await host(tester);
    final player = _Player();
    controller
      ..playlist = [DetailItem(item: PlayItem(oid: Int64(2), itemType: 2))]
      ..player = player
      ..cacheAudioQa = 30280;
    final operation = controller.playIndex(0);
    await _until(tester, () => adapter.requests.isNotEmpty);
    expect(controller.subId, isEmpty);
    adapter.reply(0, _source());
    await _complete(tester, operation);
    expect(controller.audioItem.value!.item.oid, Int64(2));
  });
}
