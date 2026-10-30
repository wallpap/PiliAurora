import 'dart:async';
import 'dart:convert';

import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/super_chat_type.dart';
import 'package:pili_aurora/models/remote/live/live_danmaku/danmaku_msg.dart';
import 'package:pili_aurora/models/remote/live/live_danmaku/live_emote.dart';
import 'package:pili_aurora/models/remote/live/live_dm_info/data.dart';
import 'package:pili_aurora/models/remote/live/live_dm_info/host_list.dart';
import 'package:pili_aurora/models/remote/live/live_superchat/item.dart';
import 'package:pili_aurora/models/remote/live/live_superchat/user_info.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/keep_alive_wrapper.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart';
import 'package:pili_aurora/common/widgets/gesture/horizontal_drag_gesture_recognizer.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/live_room/controller.dart';
import 'package:pili_aurora/pages/live_room/superchat/superchat_panel.dart';
import 'package:pili_aurora/pages/live_room/widgets/chat_panel.dart';
import 'package:pili_aurora/services/live_stream/live.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart' as ui;

class _TestController extends LiveRoomController {
  _TestController() : super('chat-test');

  final tokenRequests = <Completer<LoadingState<LiveDmInfoData>>>[];
  final historyRequests = <Completer<LoadingState<List<DanmakuMsg>?>>>[];
  final messageStreams = <_TestMessageStream>[];
  final routeQueryPolicies = <PlaybackStartPolicy?>[];

  @override
  Future<void> queryLiveUrl({
    bool autoFullScreenFlag = false,
    PlaybackStartPolicy? startPolicy,
  }) async {
    routeQueryPolicies.add(startPolicy);
  }

  @override
  Future<void> queryLiveInfoH5() async {}

  @override
  Future<LoadingState<LiveDmInfoData>> fetchLiveMessageToken(int roomId) {
    final request = Completer<LoadingState<LiveDmInfoData>>();
    tokenRequests.add(request);
    return request.future;
  }

  @override
  Future<LoadingState<List<DanmakuMsg>?>> fetchLiveMessageHistory(
    int roomId,
  ) {
    final request = Completer<LoadingState<List<DanmakuMsg>?>>();
    historyRequests.add(request);
    return request.future;
  }

  @override
  LiveMessageStream createLiveMessageStream({
    required LiveDmInfoData info,
    required int roomId,
  }) {
    final stream = _TestMessageStream(roomId);
    messageStreams.add(stream);
    return stream;
  }
}

class _TestMessageStream extends LiveMessageStream {
  _TestMessageStream(int roomId)
    : super(streamToken: '', roomId: roomId, uid: 0, servers: const []);

  void Function(dynamic)? listener;
  bool isClosed = false;

  @override
  void addEventListener(void Function(dynamic) func) => listener = func;

  @override
  Future<void> init() async {}

  @override
  void close() => isClosed = true;

  void emit(dynamic value) => listener?.call(value);
}

// 本组在内存中保存设置，不依赖磁盘存储或播放器平台插件。
class _SettingsBox implements Box<dynamic> {
  _SettingsBox([Map<dynamic, dynamic> settings = const {}])
    : _settings = Map.of(settings);

  final Map<dynamic, dynamic> _settings;

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      _settings[key] ?? defaultValue;

  @override
  Future<void> put(dynamic key, dynamic value) async => _settings[key] = value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DanmakuMsg _message(int id) => DanmakuMsg(
  name: '用户',
  text: '消息 $id',
  extra: LiveDanmaku(id: '$id', mid: 0, dmType: 0, ts: 0, ct: ''),
);

Widget _app(LiveRoomController controller, {double width = 360}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: width,
        height: 300,
        child: LiveRoomChatPanel(liveRoomController: controller, isPP: false),
      ),
    ),
  ),
);

void main() {
  setUpAll(() {
    GStorage.setting = _SettingsBox({
      SettingBoxKey.superChatType: SuperChatType.disable.index,
    });
    GStorage.video = _SettingsBox();
    GStorage.localCache = _SettingsBox({
      LocalCacheKey.buvid: 'chat-test-buvid',
    });
    Get.routing.args = 1;
  });

  _TestController createController() {
    final controller = _TestController()..onInit();
    controller.plPlayerController.showDanmaku = true;
    addTearDown(controller.onDelete.call);
    return controller;
  }

  testWidgets('进入 SC 页面后最后一条过期，仍可返回聊天', (tester) async {
    await GStorage.setting.put(
      SettingBoxKey.superChatType,
      SuperChatType.valid.index,
    );
    addTearDown(
      () => GStorage.setting.put(
        SettingBoxKey.superChatType,
        SuperChatType.disable.index,
      ),
    );
    final controller = createController()..addDm(_message(1));
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    controller.superChatMsg.add(
      SuperChatItem(
        id: 1,
        uid: 1,
        price: 30,
        backgroundColor: '#EDF5FF',
        backgroundBottomColor: '#2A60B2',
        backgroundPriceColor: '#7497CD',
        messageFontColor: '#FFFFFF',
        startSime: now,
        endTime: now + 30,
        message: '即将过期的 SC',
        token: '',
        ts: now,
        userInfo: UserInfo(
          face: '',
          faceFrame: null,
          uname: '测试用户',
          nameColor: '#666666',
        ),
        roomid: 1,
      ),
    );
    await tester.pumpWidget(
      ui.MaterialApp(
        home: ui.Scaffold(
          body: SizedBox(
            width: 360,
            height: 300,
            child: PageView(
              controller: controller.pageController,
              physics: tabBarScrollPhysics,
              onPageChanged: controller.pageIndex.call,
              horizontalDragGestureRecognizer:
                  CustomHorizontalDragGestureRecognizer.new,
              children: [
                KeepAliveWrapper(
                  child: LiveRoomChatPanel(
                    liveRoomController: controller,
                    isPP: false,
                  ),
                ),
                SuperChatPanel(controller: controller),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.textContaining('SC(1)', findRichText: true));
    await tester.pumpAndSettle();
    expect(controller.pageIndex.value, 1);
    expect(find.text('即将过期的 SC'), findsOneWidget);
    expect(find.text('返回聊天'), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(controller.superChatMsg, isEmpty);
    expect(find.text('即将过期的 SC'), findsNothing);
    expect(find.text('暂无 SC'), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(controller.pageIndex.value, 0);
    controller.pageController!.jumpToPage(1);
    await tester.pumpAndSettle();
    expect(find.text('返回聊天'), findsOneWidget);
    await tester.tap(find.text('返回聊天'));
    await tester.pumpAndSettle();
    expect(controller.pageIndex.value, 0);
    expect(find.textContaining('消息 1', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.onDelete();
  });

  const ratio = 2.0;
  for (final (unique, inline, natural, expected) in [
    ('room_1_1', false, const Size(240, 120), const Size(40, 20)),
    ('official_1', false, const Size(120, 240), const Size(20, 40)),
    ('official_2', true, const Size(180, 90), const Size(20, 10)),
    ('official_3', true, const Size(16, 12), const Size(16, 12)),
  ]) {
    testWidgets('聊天表情 $unique 在 DPR $ratio 下保持紧凑尺寸和比例', (tester) async {
      final controller = createController();
      BaseEmote emote(String unique, double width, double height) =>
          BaseEmote.fromJson({
            'url': 'https://example.test/emote.png',
            'emoticon_unique': unique,
            'width': width,
            'height': height,
          });
      final imageEmote = emote(unique, natural.width, natural.height);
      controller.addDm(
        DanmakuMsg(
          name: '用户',
          text: '[表情]',
          uemote: inline ? null : imageEmote,
          emots: inline ? {'[表情]': imageEmote} : null,
          extra: _message(1).extra,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(devicePixelRatio: ratio),
            child: child!,
          ),
          home: Scaffold(
            body: LiveRoomChatPanel(
              liveRoomController: controller,
              isPP: false,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final image = tester.widget<NetworkImgLayer>(
        find.byType(NetworkImgLayer),
      );
      expect(image.width, expected.width);
      expect(image.height, expected.height);
      expect(tester.getSize(find.byType(NetworkImgLayer)), expected);
      expect(tester.takeException(), isNull);
      controller.onDelete();
    });
  }

  testWidgets(
    'same length history updates publish newest content every batch',
    (tester) async {
      final controller = createController();
      for (var i = 0; i < 500; i++) {
        controller.addDm(_message(i));
      }
      await tester.pumpWidget(_app(controller));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('消息 499', findRichText: true), findsOneWidget);
      controller.addDm(_message(500));
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.messages.value.length, 500);
      expect(find.textContaining('消息 500', findRichText: true), findsOneWidget);
      expect(controller.shouldRefresh, isFalse);
      controller.onDelete();
    },
  );

  testWidgets(
    'scrolling up freezes history and jump button merges bounded unread messages',
    (tester) async {
      final controller = createController();
      for (var i = 0; i < 500; i++) {
        controller.addDm(_message(i));
      }
      await tester.pumpWidget(_app(controller, width: 280));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.drag(find.byType(ListView), const Offset(0, 240));
      await tester.pumpAndSettle();
      expect(controller.disableAutoScroll.value, isTrue);
      final offset = controller.scrollController.offset;
      final frozen = controller.messages.value;
      for (var i = 500; i < 100500; i++) {
        controller.addDm(_message(i));
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.messages.value, same(frozen));
      expect(controller.scrollController.offset, offset);
      expect(controller.unreadMessages.value, (500, 99500));
      expect(find.text('回到底部 · 500 条新消息\n已略过 99500 条'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('回到底部 · 500 条新消息\n已略过 99500 条'));
      await tester.pumpAndSettle();
      expect(controller.disableAutoScroll.value, isFalse);
      expect(controller.unreadMessages.value, (0, 0));
      expect(controller.messages.value.length, 500);
      expect(controller.messages.value.last.content.text, '消息 100499');
      expect(controller.scrollController.offset, 0);
      controller.onDelete();
    },
  );

  testWidgets(
    'background recovery merges backlog while history reading stays frozen',
    (tester) async {
      final controller = createController()..addDm(_message(0));
      await tester.pumpWidget(_app(controller));
      await tester.pump(const Duration(milliseconds: 100));
      controller.plPlayerController.showDanmaku = false;
      for (var i = 1; i <= 600; i++) {
        controller.addDm(_message(i));
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.messages.value.single.content.text, '消息 0');
      controller.refreshMsgIfNeeded();
      controller.plPlayerController.showDanmaku = true;
      await tester.pumpAndSettle();
      expect(controller.messages.value.last.content.text, '消息 600');
      expect(controller.unreadMessages.value, (0, 0));

      controller.disableAutoScroll.value = true;
      final frozen = controller.messages.value;
      controller.plPlayerController.showDanmaku = false;
      controller
        ..addDm(_message(601))
        ..refreshMsgIfNeeded();
      controller.plPlayerController.showDanmaku = true;
      await tester.pumpAndSettle();
      expect(controller.messages.value, same(frozen));
      expect(controller.unreadMessages.value, (1, 0));
      controller.onDelete();
    },
  );

  testWidgets('closing a message menu resumes queued messages immediately', (
    tester,
  ) async {
    final controller = createController()..addDm(_message(0));
    await tester.pumpWidget(_app(controller));
    await tester.pump(const Duration(milliseconds: 100));
    controller
      ..autoScroll = false
      ..addDm(_message(1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.messages.value.length, 1);
    controller
      ..autoScroll = true
      ..refreshMsgIfNeeded();
    await tester.pumpAndSettle();
    expect(controller.messages.value.length, 2);
    expect(controller.messages.value.last.content.text, '消息 1');
    expect(controller.unreadMessages.value, (0, 0));
    controller.onDelete();
  });

  testWidgets('scrolling back near the bottom resumes unread messages', (
    tester,
  ) async {
    final controller = createController();
    for (var i = 0; i < 500; i++) {
      controller.addDm(_message(i));
    }
    await tester.pumpWidget(_app(controller));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.drag(find.byType(ListView), const Offset(0, 240));
    await tester.pumpAndSettle();
    expect(controller.disableAutoScroll.value, isTrue);
    controller.addDm(_message(500));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(controller.disableAutoScroll.value, isFalse);
    expect(controller.unreadMessages.value, (0, 0));
    expect(controller.messages.value.last.content.text, '消息 500');
    expect(controller.scrollController.offset, 0);
    controller.onDelete();
  });

  testWidgets(
    'closing the room clears buffers and ignores late refresh or messages',
    (tester) async {
      final controller = createController()..addDm(_message(0));
      await tester.pumpWidget(_app(controller));
      controller
        ..onDelete()
        ..addDm(_message(1))
        ..refreshMsgIfNeeded();
      await tester.pump(const Duration(seconds: 1));
      expect(controller.messages.value, isEmpty);
      expect(controller.chatBuffer.historyCount, 0);
      expect(controller.chatBuffer.pendingCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'repeated message starts share one token request and connection',
    () async {
      final controller = createController();
      final first = controller.startLiveMsg();
      final second = controller.startLiveMsg();

      expect(controller.tokenRequests, hasLength(1));
      expect(controller.historyRequests, hasLength(1));
      controller.historyRequests.single.complete(const Success(null));
      controller.tokenRequests.single.complete(
        Success(_messageInfo('shared')),
      );
      await Future.wait([first, second]);

      expect(controller.messageStreams, hasLength(1));
      expect(controller.dmInfo?.token, 'shared');
      await controller.startLiveMsg();
      expect(controller.tokenRequests, hasLength(1));
      expect(controller.messageStreams, hasLength(1));
    },
  );

  test(
    'failed token request clears the single-flight slot for retry',
    () async {
      final controller = createController();
      final failedStart = controller.startLiveMsg();
      controller.historyRequests.single.complete(const Success(null));
      controller.tokenRequests.single.completeError(
        StateError('network failed'),
      );
      await failedStart;

      final retry = controller.startLiveMsg();
      expect(controller.tokenRequests, hasLength(2));
      controller.tokenRequests.last.complete(Success(_messageInfo('retry')));
      await retry;

      expect(controller.messageStreams, hasLength(1));
      expect(controller.dmInfo?.token, 'retry');
    },
  );

  test(
    'pause invalidates late token and history results before resume',
    () async {
      final controller = createController();
      final oldStart = controller.startLiveMsg();
      final oldToken = controller.tokenRequests.single;
      final oldHistory = controller.historyRequests.single;

      controller.closeLiveMsg();
      final currentStart = controller.startLiveMsg();
      final currentToken = controller.tokenRequests.last;
      final currentHistory = controller.historyRequests.last;
      expect(controller.tokenRequests, hasLength(2));
      expect(controller.historyRequests, hasLength(2));

      oldToken.complete(Success(_messageInfo('old')));
      oldHistory.complete(Success([_message(101)]));
      await oldStart;
      await Future<void>.delayed(Duration.zero);
      expect(controller.dmInfo, isNull);
      expect(controller.chatBuffer.historyCount, 0);
      expect(controller.messageStreams, isEmpty);

      currentToken.complete(Success(_messageInfo('current')));
      currentHistory.complete(const Success(null));
      await currentStart;
      expect(controller.dmInfo?.token, 'current');
      expect(controller.messageStreams, hasLength(1));
    },
  );

  test('closed stream callbacks cannot update chat after resume', () async {
    final controller = createController();
    final initial = controller.startLiveMsg();
    controller.historyRequests.single.complete(const Success(null));
    controller.tokenRequests.single.complete(Success(_messageInfo('first')));
    await initial;
    final oldStream = controller.messageStreams.single;
    final emitOldStream = oldStream.emit;
    emitOldStream(_danmakuEvent(1));
    expect(controller.chatBuffer.historyCount, 1);

    controller.closeLiveMsg();
    await controller.startLiveMsg();
    final currentStream = controller.messageStreams.last;
    expect(oldStream.isClosed, isTrue);
    emitOldStream(_danmakuEvent(2));
    expect(controller.chatBuffer.historyCount, 1);
    currentStream.emit(_danmakuEvent(3));
    expect(controller.chatBuffer.historyCount, 2);
  });

  test('直播手动重试重新查询地址并保留播放意图', () async {
    final controller = createController();
    controller.routeQueryPolicies.clear();
    await controller.retryPlayback();
    expect(controller.routeQueryPolicies, [PlaybackStartPolicy.preserve]);
  });

  test(
    'route return re-resolves a plan canceled before it was accepted',
    () async {
      final controller = createController();
      controller.routeQueryPolicies.clear();

      final holdForRoute = controller.holdPlaybackForRoute;
      final restoreAfterRoute = controller.restorePlaybackAfterRoute;
      holdForRoute();
      await restoreAfterRoute();

      expect(controller.routeQueryPolicies, [PlaybackStartPolicy.preserve]);
      controller.onDelete();
    },
  );
}

LiveDmInfoData _messageInfo(String token) => LiveDmInfoData(
  token: token,
  hostList: [HostList(host: 'messages.test', wssPort: 443)],
);

Map<String, dynamic> _danmakuEvent(int id) {
  final first = List<dynamic>.filled(16, null);
  first[15] = {
    'user': {
      'uid': 42,
      'base': {'name': '用户'},
      'medal': null,
    },
    'extra': jsonEncode({
      'id_str': '$id',
      'dm_type': 0,
      'mode': 1,
      'color': 16777215,
    }),
  };
  final info = List<dynamic>.filled(10, null)
    ..[0] = first
    ..[1] = '消息 $id'
    ..[9] = {'ts': 1, 'ct': ''};
  return {'cmd': 'DANMU_MSG', 'info': info};
}
