import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart' show Player;
import 'package:pili_aurora/common/widgets/pair.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/sponsor_block/action_type.dart';
import 'package:pili_aurora/models/common/sponsor_block/post_segment_model.dart';
import 'package:pili_aurora/models/common/sponsor_block/segment_type.dart';
import 'package:pili_aurora/models/remote/sponsor_block/segment_item.dart';
import 'package:pili_aurora/pages/sponsor_block/block_mixin.dart';
import 'package:pili_aurora/pages/sponsor_block/view.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/pages/video/post_panel/view.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/controlled_http_adapter.dart';
import '../../support/memory_box.dart';

class _Video extends GetxController implements VideoDetailController {
  @override
  String bvid = 'video';
  @override
  final cid = 1.obs;
  @override
  final postList = <PostSegmentModel>[];
  int handled = 0;
  int initSkipCount = 0;

  @override
  StreamSubscription<Duration>? get blockListener => null;
  @override
  void initSkip() {
    initSkipCount++;
  }

  @override
  Future<void> handleSBData(List<SegmentItemModel> list) async {
    handled++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player extends GetxController implements PlPlayerController {
  @override
  int get durationInMilliseconds => 60000;
  @override
  int get positionInMilliseconds => 2000;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Config with BlockConfigMixin {}

class _Block extends GetxController with BlockMixin {
  @override
  final blockConfig = _Config();
  @override
  Player? get player => null;
  @override
  bool get autoPlay => false;
  @override
  int? get timeLength => 60000;
  @override
  bool get preInitPlayer => false;
  @override
  int get currPosInMilliseconds => 0;
  @override
  bool get isUgc => true;
  @override
  Future<void> applyBlockMute(bool muted) async {}
  @override
  Future<void>? seekTo(Duration duration, {required bool isSeek}) => null;
  final handled = <List<SegmentItemModel>>[];
  final firstConsumer = Completer<void>();
  Completer<void>? consumerGate;
  @override
  Future<void> handleSBData(List<SegmentItemModel> list) async {
    handled.add(list);
    if (!firstConsumer.isCompleted) firstConsumer.complete();
    await consumerGate?.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final adapter = ControlledHttpAdapter();
  late _Video video;
  late _Block block;
  setUpAll(() {
    GStorage.setting = MemoryBox({SettingBoxKey.blockUserID: 'synthetic-user'});
    GStorage.video = MemoryBox();
    Request();
    Request.dio.interceptors.clear();
    Request.dio.httpClientAdapter = adapter;
  });
  setUp(() {
    adapter.requests.clear();
    adapter.pending.clear();
    video = _Video()
      ..postList.add(
        PostSegmentModel(
          segment: Pair(first: 0.0, second: 2.0),
          category: SegmentType.intro,
          actionType: ActionType.skip,
        ),
      );
    block = _Block();
  });
  tearDown(() {
    video.onDelete();
    block.onDelete();
    Get.reset();
  });
  tearDownAll(() => Request.dio.close(force: true));

  Future<void> until(WidgetTester tester, bool Function() condition) async {
    final deadline = tester.binding.clock.now().add(const Duration(seconds: 3));
    while (!condition() && tester.binding.clock.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(condition(), isTrue);
    await tester.pump();
  }

  Future<void> mount(WidgetTester tester, {bool settings = false}) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: Scaffold(
          body: TextButton(
            onPressed: () => Get.to(
              () => settings
                  ? const SponsorBlockPage()
                  : PrimaryScrollController(
                      controller: scroll,
                      child: PostPanel(
                        enableSlide: false,
                        videoDetailController: video,
                        plPlayerController: _Player(),
                      ),
                    ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.tap(find.byTooltip('提交'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定提交'));
    await until(tester, () => adapter.requests.length == 1);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('片段提交期间禁用重复提交，待确认保留草稿和当前面板', (tester) async {
    await mount(tester);
    await submit(tester);
    expect(
      tester
          .widget<FloatingActionButton>(find.byType(FloatingActionButton))
          .onPressed,
      isNull,
    );
    expect(adapter.requests.single.extra['noRetry'], isTrue);
    adapter.pending[0].complete(ResponseBody.fromString('private body', 500));
    await until(tester, () => find.byTooltip('提交').evaluate().isNotEmpty);
    expect(video.postList, hasLength(1));
    expect(video.handled, 0);
    expect(find.textContaining('操作结果待确认'), findsOneWidget);
    expect(find.text('提交片段'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('确认成功后清除本次草稿，交付片段并只关闭所属面板', (tester) async {
    await mount(tester);
    await submit(tester);
    adapter.json(0, []);
    await until(tester, () => video.handled == 1);
    await tester.pumpAndSettle();
    expect(video.postList, isEmpty);
    expect(video.initSkipCount, 1);
    expect(find.text('提交片段'), findsNothing);
    expect(find.text('打开'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('面板关闭后提交迟到成功不关闭新页面、不改写其草稿', (tester) async {
    await mount(tester);
    await submit(tester);
    Get.back();
    await tester.pumpAndSettle();
    Get.to(() => const Scaffold(body: Text('新页面')));
    await tester.pumpAndSettle();
    adapter.json(0, []);
    await until(tester, () => find.text('提交成功').evaluate().isNotEmpty);
    expect(find.text('新页面'), findsOneWidget);
    expect(video.postList, hasLength(1));
    expect(video.handled, 0);
    await finish(tester);
  });

  testWidgets('切换视频后的提交结果不注入当前视频', (tester) async {
    await mount(tester);
    await submit(tester);
    video.cid.value = 2;
    adapter.json(0, []);
    await until(tester, () => find.byTooltip('提交').evaluate().isNotEmpty);
    expect(video.handled, 0);
    expect(video.postList, hasLength(1));
    await finish(tester);
  });

  testWidgets('同一片段不能并发投票，待确认文案不变为明确失败', (tester) async {
    await mount(tester);
    final first = block.voteBlockSegment(uuid: 'segment', type: 1);
    await until(tester, () => adapter.requests.length == 1);
    await block.voteBlockSegment(uuid: 'segment', category: SegmentType.intro);
    expect(adapter.requests, hasLength(1));
    adapter.pending[0].complete(ResponseBody.fromString('', 500));
    await until(
      tester,
      () => find.textContaining('操作结果待确认').evaluate().isNotEmpty,
    );
    await first;
    var completed = false;
    final second = block.voteBlockSegment(uuid: 'segment', type: 0)
      ..then<void>((_) {
        completed = true;
      });
    await until(tester, () => adapter.requests.length == 2);
    block.resetBlock();
    adapter.pending[1].complete(ResponseBody.fromString('', 200));
    await until(tester, () => completed);
    await second;
    await tester.pumpAndSettle();
    expect(find.text('投票成功'), findsNothing);
    await finish(tester);
  });

  testWidgets('服务器状态显示失败原因与重试进度，旧查询不能覆盖新结果', (tester) async {
    await mount(tester, settings: true);
    await until(tester, () => adapter.requests.length == 2);
    adapter.pending[0].complete(ResponseBody.fromString('', 429));
    adapter.json(1, {'viewCount': 1, 'minutesSaved': 2, 'segmentCount': 3});
    await until(tester, () => find.text('提交太快，请稍后再试').evaluate().isNotEmpty);
    await tester.tap(find.text('服务器状态'));
    await until(tester, () => adapter.requests.length == 3);
    expect(find.text('检查中'), findsOneWidget);
    await tester.tap(find.text('服务器状态'));
    await until(tester, () => adapter.requests.length == 4);
    adapter.pending[3].complete(ResponseBody.fromString('123', 200));
    await until(tester, () => find.text('正常').evaluate().isNotEmpty);
    adapter.pending[2].complete(ResponseBody.fromString('', 500));
    await tester.pumpAndSettle();
    expect(find.text('正常'), findsOneWidget);
    expect(find.text('服务器无法获取信息'), findsNothing);
    await finish(tester);
  });

  test('查询的 Future 等待片段消费者完成，旧响应不进入消费者', () async {
    final gate = Completer<void>();
    block.consumerGate = gate;
    var completed = false;
    final first = block.querySponsorBlock(bvid: 'video', cid: 1)
      ..then<void>((_) {
        completed = true;
      });
    await adapter.waitForRequests(1);
    adapter.json(0, []);
    await block.firstConsumer.future;
    expect(block.handled, hasLength(1));
    expect(completed, isFalse);
    gate.complete();
    await first;
    expect(completed, isTrue);
    final stale = block.querySponsorBlock(bvid: 'video', cid: 1);
    await adapter.waitForRequests(2);
    block.resetBlock();
    adapter.json(1, []);
    await stale;
    expect(block.handled, hasLength(1));
  });
}
