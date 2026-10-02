import 'package:pili_aurora/models/common/super_chat_type.dart';
import 'package:pili_aurora/models_new/live/live_danmaku/danmaku_msg.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/live_room/controller.dart';
import 'package:pili_aurora/pages/live_room/widgets/chat_panel.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';

class _TestController extends LiveRoomController {
  _TestController() : super('chat-test');

  @override
  Future<void> queryLiveUrl({bool autoFullScreenFlag = false}) async {}

  @override
  Future<void> queryLiveInfoH5() async {}
}

// 本组只读取设置，不依赖磁盘存储或播放器平台插件。
class _SettingsBox implements Box<dynamic> {
  _SettingsBox([this._settings = const {}]);

  final Map<dynamic, dynamic> _settings;

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      _settings[key] ?? defaultValue;

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
}
