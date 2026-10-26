import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/super_chat_type.dart';
import 'package:pili_aurora/models/remote/live/live_danmaku/danmaku_msg.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/live_room/view.dart' show LiveRoomPage;
import 'package:pili_aurora/pages/live_room/widgets/bottom_control.dart';
import 'package:pili_aurora/pages/live_room/widgets/header_control.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_status.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/theme_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final adapter = _PendingAdapter();

  setUpAll(() {
    GStorage.setting = _SettingsBox({
      SettingBoxKey.superChatType: SuperChatType.disable.index,
    });
    GStorage.video = _SettingsBox();
    GStorage.localCache = _SettingsBox({
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
      LocalCacheKey.mixinKey: 'synthetic-test-key',
    });
    Request();
    Request.dio.interceptors.clear();
    Request.dio.httpClientAdapter = adapter;
    ThemeUtils.getAllTheme();
    Get.testMode = true;
  });

  tearDownAll(() => Request.dio.close(force: true));

  testWidgets('直播请求持续未完成时先显示加载动画和可操作的控件', (tester) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      Get.reset();
      await tester.pump();
    });
    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: SizedBox.expand())),
    );
    unawaited(Get.to<void>(() => const LiveRoomPage(), arguments: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(LiveHeaderControl), findsOneWidget);
    final controller = tester
        .widget<LiveHeaderControl>(find.byType(LiveHeaderControl))
        .liveController;
    expect(controller.isLoaded.value, isFalse);
    expect(find.byType(BottomControl), findsOneWidget);
    expect(find.text('加载中...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    controller.plPlayerController.isBuffering.value = false;
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('加载中...'), findsOneWidget);
    final requestId =
        controller.plPlayerController.currentPlaybackSnapshot.requestId ?? 0;
    await tester.tap(find.byTooltip('刷新'));
    await tester.pump();
    expect(
      controller.plPlayerController.currentPlaybackSnapshot.requestId,
      greaterThan(requestId),
    );

    controller.plPlayerController.dataStatus.value = DataStatus.error;
    await tester.pump();
    expect(find.text('加载失败，点击重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.onDelete();
    Get.reset();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('长时间停留并积压直播消息后可以返回并释放页面', (tester) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      Get.reset();
      await tester.pump();
    });
    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: Text('直播列表'))),
    );
    unawaited(Get.to<void>(() => const LiveRoomPage(), arguments: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final controller = tester
        .widget<LiveHeaderControl>(find.byType(LiveHeaderControl))
        .liveController;
    controller.plPlayerController.showDanmaku = true;
    controller.addDm(_message(0));
    await tester.pump(const Duration(milliseconds: 100));
    controller.disableAutoScroll.value = true;
    for (var i = 1; i <= 100000; i++) {
      controller.addDm(_message(i));
    }
    await tester.pump(const Duration(hours: 4));
    expect(controller.chatBuffer.pendingCount, 500);
    expect(controller.chatBuffer.droppedPending, 99500);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('直播列表'), findsOneWidget);
    expect(find.byType(LiveRoomPage), findsNothing);
    expect(controller.isClosed, isTrue);
    expect(controller.chatBuffer.historyCount, 0);
    expect(controller.chatBuffer.pendingCount, 0);
    controller
      ..addDm(_message(100001))
      ..refreshMsgIfNeeded();
    await tester.pump(const Duration(seconds: 1));
    expect(controller.messages.value, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

DanmakuMsg _message(int id) => DanmakuMsg(
  name: '用户',
  text: '消息 $id',
  extra: LiveDanmaku(id: '$id', mid: 0, dmType: 0, ts: 0, ct: ''),
);

class _PendingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final response = Completer<ResponseBody>();
    cancelFuture?.then((_) {
      response.completeError(
        DioException.requestCancelled(
          requestOptions: options,
          reason: 'test finished',
        ),
      );
    });
    return response.future;
  }

  @override
  void close({bool force = false}) {}
}

class _SettingsBox implements Box<dynamic> {
  _SettingsBox([Map<dynamic, dynamic> values = const {}])
    : _values = Map.of(values);
  final Map<dynamic, dynamic> _values;

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      _values[key] ?? defaultValue;

  @override
  Future<void> put(dynamic key, dynamic value) async => _values[key] = value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
