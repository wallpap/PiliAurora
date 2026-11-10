import 'dart:async';

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
import 'package:pili_aurora/models/remote/video/video_detail/page.dart';
import 'package:pili_aurora/services/audio_handler.dart';
import 'package:pili_aurora/services/service_locator.dart';
import 'package:pili_aurora/utils/storage_key.dart';

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
  void reply(int index, PlayURLResp response) => pending[index].complete(
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
  late _Player player;
  late AudioController controller;
  var creations = 0;
  var failCreation = false;
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
    adapter = _Adapter();
    Request.dio.httpClientAdapter = adapter;
    player = _Player();
    creations = 0;
    failCreation = false;
    controller =
        AudioController(
            createPlayer: (_) async {
              creations++;
              if (failCreation) {
                throw StateError('https://private?token=secret');
              }
              return player;
            },
          )
          ..cacheAudioQa = 30280
          ..playlist = [
            for (var id = 1; id <= 3; id++)
              DetailItem(
                item: PlayItem(oid: Int64(id), subId: [Int64(id)], itemType: 2),
              ),
          ];
    controller.animController = AnimationController(
      vsync: controller,
      duration: const Duration(milliseconds: 200),
    );
  });
  tearDown(() {
    controller.onClose();
    adapter.close();
  });
  tearDownAll(() => Request.dio.close(force: true));

  Future<void> host(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(builder: FlutterSmartDialog.init(), home: const SizedBox()),
    );
  }

  _check('empty playback data is consumed and does not select the item', (
    tester,
  ) async {
    await host(tester);
    final operation = controller.playIndex(0);
    await tester.pump();
    await _until(tester, () => adapter.requests.isNotEmpty);
    adapter.reply(0, PlayURLResp());
    await tester.pump();
    await _complete(tester, operation);
    expect(controller.audioItem.value, isNull);
    expect(creations, 0);
    await tester.pump();
    expect(find.text('音频播放失败，请重试'), findsOneWidget);
  });

  _check('blank playback URLs do not initialize a player', (tester) async {
    await host(tester);
    final operation = controller.playIndex(0);
    await tester.pump();
    await _until(tester, () => adapter.requests.isNotEmpty);
    adapter.reply(0, _source('   '));
    await tester.pump();
    await _complete(tester, operation);
    expect(creations, 0);
    expect(controller.audioItem.value, isNull);
  });

  _check('late playback response cannot open or select an earlier item', (
    tester,
  ) async {
    await host(tester);
    final first = controller.playIndex(0);
    await tester.pump();
    await _until(tester, () => adapter.requests.isNotEmpty);
    final second = controller.playIndex(1);
    await tester.pump();
    await _until(tester, () => adapter.requests.length >= 2);
    adapter.reply(1, _source('https://media.example/new'));
    await tester.pump();
    await _complete(tester, second);
    adapter.reply(0, _source('https://media.example/old'));
    await tester.pump();
    await _complete(tester, first);
    expect(player.opened, ['https://media.example/new']);
    expect(controller.audioItem.value!.item.oid, Int64(2));
  });

  _check(
    'player creation failure can retry and open completion owns selection',
    (tester) async {
      await host(tester);
      failCreation = true;
      final first = controller.playIndex(0);
      await tester.pump();
      await _until(tester, () => adapter.requests.isNotEmpty);
      adapter.reply(0, _source());
      await tester.pump();
      await _complete(tester, first);
      expect(controller.audioItem.value, isNull);
      failCreation = false;
      player.opening = Completer<void>();
      final second = controller.playIndex(0);
      await tester.pump();
      await _until(tester, () => adapter.requests.length >= 2);
      adapter.reply(1, _source());
      await tester.pump();
      expect(controller.audioItem.value, isNull);
      player.opening!.complete();
      await tester.pump();
      await _complete(tester, second);
      expect(creations, 2);
      expect(controller.audioItem.value!.item.oid, Int64(1));
    },
  );
  _check('account replacement discards a pending playback URL', (
    tester,
  ) async {
    await host(tester);
    final originalAccount = Accounts.main;
    final operation = controller.playIndex(0);
    await tester.pump();
    await _until(tester, () => adapter.requests.isNotEmpty);
    Accounts.accountMode[AccountType.main.index] = const NoAccount();
    try {
      adapter.reply(0, _source());
      await tester.pump();
      await _complete(tester, operation);
      expect(player.opened, isEmpty);
      expect(controller.audioItem.value, isNull);
    } finally {
      Accounts.accountMode[AccountType.main.index] = originalAccount;
    }
  });
  _check('a new selection waits for old open and confirms only the new item', (
    tester,
  ) async {
    await host(tester);
    player.opening = Completer<void>();
    final first = controller.playIndex(0);
    await _until(tester, () => adapter.requests.length == 1);
    adapter.reply(0, _source('https://media.example/old'));
    await _until(tester, () => player.opened.length == 1);
    final second = controller.playIndex(1);
    await _until(tester, () => adapter.requests.length == 2);
    adapter.reply(1, _source('https://media.example/new'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(player.opened, ['https://media.example/old']);
    expect(controller.audioItem.value, isNull);
    player.opening!.complete();
    await _complete(tester, first);
    await _complete(tester, second);
    expect(player.opened, [
      'https://media.example/old',
      'https://media.example/new',
    ]);
    expect(controller.audioItem.value!.item.oid, Int64(2));
  });
  _check('open failure is consumed before confirming the selected item', (
    tester,
  ) async {
    await host(tester);
    player.openError = StateError('https://private?token=secret');
    final operation = controller.playIndex(0);
    await _until(tester, () => adapter.requests.isNotEmpty);
    adapter.reply(0, _source());
    await _complete(tester, operation);
    expect(controller.audioItem.value, isNull);
    expect(find.textContaining('secret'), findsNothing);
    await tester.pump();
    expect(find.text('音频播放失败，请重试'), findsOneWidget);
  });
  _check(
    'same target is skipped while pending or ready and another part can play',
    (tester) async {
      await host(tester);
      final operation = controller.playIndex(0);
      await _until(tester, () => adapter.requests.isNotEmpty);
      await controller.playIndex(0, subId: [Int64.ONE]);
      await tester.pump(const Duration(milliseconds: 100));
      expect(adapter.requests.length, 1);
      adapter.reply(0, _source());
      await _complete(tester, operation);
      await controller.playIndex(0);
      await controller.playIndex(0, subId: [Int64.ONE]);
      await tester.pump(const Duration(milliseconds: 100));
      expect(adapter.requests.length, 1);
      final nextPart = controller.playIndex(0, subId: [Int64(10)]);
      await _until(tester, () => adapter.requests.length == 2);
      adapter.reply(1, _source('https://media.example/part'));
      await _complete(tester, nextPart);
      expect(controller.subId, [Int64(10)]);
      expect(player.opened.length, 2);
    },
  );

  _check('late seek does not publish the position into a newer song', (
    tester,
  ) async {
    await host(tester);
    final first = controller.playIndex(0);
    await _until(tester, () => adapter.requests.length == 1);
    adapter.reply(0, _source());
    await _complete(tester, first);
    player.seeking = Completer<void>();
    final seek = controller.onSeek(const Duration(seconds: 30));
    final second = controller.playIndex(1);
    await _until(tester, () => adapter.requests.length == 2);
    adapter.reply(1, _source('https://media.example/new'));
    await _complete(tester, second);
    controller.position.value = 2;
    player.seeking!.complete();
    await seek;
    expect(controller.position.value, 2);
    expect(controller.audioItem.value!.item.oid, Int64(2));
  });

  _check('old playback metadata cannot replace a newer system owner', (
    tester,
  ) async {
    await host(tester);
    final handler = VideoPlayerServiceHandler()..enableBackgroundPlay = true;
    videoPlayerServiceHandler = handler;
    handler
      ..onPlay = (() async {})
      ..onVideoDetailChange(Part(part: 'new owner'), 2, 'new owner');
    try {
      final operation = controller.playIndex(0);
      await _until(tester, () => adapter.requests.length == 1);
      adapter.reply(0, _source());
      await _complete(tester, operation);
      expect(controller.audioItem.value!.item.oid, Int64.ONE);
      expect(handler.mediaItem.value?.title, 'new owner');
    } finally {
      videoPlayerServiceHandler = null;
      handler.clear();
    }
  });
}
