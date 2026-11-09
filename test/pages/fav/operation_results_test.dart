import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/video/video_detail/stat_detail.dart';
import 'package:pili_aurora/pages/common/common_intro_controller.dart';
import 'package:pili_aurora/pages/fav_create/view.dart';
import 'package:pili_aurora/pages/fav_panel/view.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _Intro extends CommonIntroController {
  int favoriteChanges = 0;

  @override
  (Object, int) get getFavRidType => (42, 2);
  @override
  int get copyright => 1;
  @override
  StatDetail? getStat() => null;
  @override
  void updateFavCount(int count) => favoriteChanges += count;
  @override
  void queryVideoIntro() {}
  @override
  bool prevPlay() => false;
  @override
  bool nextPlay() => false;
  @override
  void actionShareVideo(BuildContext context) {}
  @override
  void actionTriple() {}
  @override
  void actionLikeVideo() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  final account = LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'synthetic-csrf'}),
    null,
    null,
  );
  late Account previous;
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    previous = Accounts.main;
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() {
    Accounts.accountMode[AccountType.main.index] = account;
    requests.clear();
  });
  tearDown(Get.reset);
  tearDownAll(() async {
    Accounts.accountMode[AccountType.main.index] = previous;
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> mount(WidgetTester tester, [Widget? home]) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: home ?? const Scaffold(),
        getPages: [GetPage(name: '/create', page: () => const CreateFavPage())],
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    // 弹层生命周期包含独立于 ticker 的动画预算与帧末回调。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 3),
    );
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
  }

  Future<void> dispatched(WidgetTester tester, int count) async {
    final deadline = tester.binding.clock.now().add(const Duration(seconds: 3));
    // Dio 的请求拦截器也排入事件队列，等待真实到达并推进测试时钟。
    while (requests.length < count &&
        tester.binding.clock.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(requests, hasLength(count));
  }

  test('动作异常沿 Future 返回，同时释放防重复操作的锁', () async {
    final controller = _Intro();
    addTearDown(controller.onClose);
    final cause = StateError('synthetic action failure');
    await expectLater(
      controller.handleAction(() => Future<void>.error(cause)),
      throwsA(same(cause)),
    );
    expect(controller.isProcessing, isFalse);
    var ran = false;
    await controller.handleAction(() {
      ran = true;
    });
    expect(ran, isTrue);
  });

  testWidgets('快速收藏等待实际写入，失败显示写入错误且不重复提交', (tester) async {
    await mount(tester);
    final controller = _Intro();
    addTearDown(controller.onClose);
    var completed = false;
    final action = controller.actionFavVideo(isQuick: true)
      ..then<void>((_) {
        completed = true;
      });
    await tester.pump();
    await dispatched(tester, 1);
    await controller.actionFavVideo(isQuick: true);
    expect(requests, hasLength(1));
    requests[0].reply.complete({
      'code': 0,
      'data': {
        'list': [
          {'id': 7},
        ],
      },
    });
    await tester.pump();
    await dispatched(tester, 2);
    expect(completed, isFalse);
    expect(requests[1].options.path, Api.favVideo);
    requests[1].reply.complete({'code': -403, 'message': '收藏被拒绝'});
    await settle(tester);
    await action;
    expect(find.text('收藏被拒绝'), findsOneWidget);
    expect(controller.hasFav.value, isFalse);
    expect(controller.favoriteChanges, 0);
    expect(completed, isTrue);
    await finish(tester);
  });

  testWidgets('稍后再看防重复写入，待确认和切换视频后不修改当前状态', (tester) async {
    await mount(tester);
    final controller = _Intro()
      ..bvid = 'BV1xx411c7mD'
      ..hasLater = false.obs;
    addTearDown(controller.onClose);
    final add = controller.viewLater();
    await dispatched(tester, 1);
    await controller.viewLater();
    expect(requests, hasLength(1));
    requests[0].reply.complete({'code': '0'});
    await settle(tester);
    await add;
    expect(controller.hasLater.value, isFalse);
    expect(find.text('操作结果待确认，请先核对后再操作'), findsOneWidget);

    final retry = controller.viewLater();
    await dispatched(tester, 2);
    controller.bvid = 'BV1newVideo';
    requests[1].reply.complete({'code': 0});
    await settle(tester);
    await retry;
    expect(controller.hasLater.value, isFalse);
    await finish(tester);
  });

  testWidgets('没有收藏夹时结束加载并提示创建，不发送无效写入', (tester) async {
    await mount(tester);
    final controller = _Intro();
    addTearDown(controller.onClose);
    final action = controller.actionFavVideo(isQuick: true);
    await tester.pump();
    await dispatched(tester, 1);
    requests[0].reply.complete({
      'code': 0,
      'data': {'list': []},
    });
    await settle(tester);
    await action;
    expect(requests, hasLength(1));
    expect(find.text('暂无可用收藏夹，请先创建'), findsOneWidget);
    expect(controller.favFolderId, isNull);
    await finish(tester);
  });

  testWidgets('快速收藏查询期间切号，不用旧收藏夹向新账号写入', (tester) async {
    await mount(tester);
    final controller = _Intro();
    addTearDown(controller.onClose);
    final action = controller.actionFavVideo(isQuick: true);
    await tester.pump();
    await dispatched(tester, 1);
    Accounts.accountMode[AccountType.main.index] = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '2'}),
      null,
      null,
    );
    requests[0].reply.complete({
      'code': 0,
      'data': {
        'list': [
          {'id': 7},
        ],
      },
    });
    await settle(tester);
    await action;
    expect(requests, hasLength(1));
    expect(controller.favFolderData.value.list, isNull);
    expect(controller.favoriteChanges, 0);
    await finish(tester);
  });

  testWidgets('收藏夹列表缺失时选择面板呈现空状态', (tester) async {
    final controller = _Intro();
    addTearDown(controller.onClose);
    await mount(tester, FavPanel(ctr: controller));
    await dispatched(tester, 1);
    requests[0].reply.complete({'code': 0, 'data': <String, dynamic>{}});
    await settle(tester);
    expect(find.text('暂无收藏夹，请先创建'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('创建期间禁用重复提交，缺失 ID 保留草稿并提示核对', (tester) async {
    await mount(tester);
    Get.toNamed('/create');
    await settle(tester);
    await tester.enterText(find.byType(TextField).first, '我的收藏夹');
    await tester.tap(find.text('完成'));
    await tester.pump();
    await dispatched(tester, 1);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '完成'))
          .onPressed,
      isNull,
    );
    expect(requests, hasLength(1));
    requests[0].reply.complete({'code': 0, 'data': {}});
    await settle(tester);
    expect(find.textContaining('操作结果待确认'), findsOneWidget);
    expect(find.text('我的收藏夹'), findsOneWidget);
    expect(Get.currentRoute, '/create');
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '完成'))
          .onPressed,
      isNotNull,
    );
    await finish(tester);
  });

  testWidgets('编辑标题为空时仍结束加载并允许填写名称', (tester) async {
    await mount(tester);
    Get.toNamed('/create?mediaId=7');
    await tester.pump();
    await dispatched(tester, 1);
    requests[0].reply.complete({
      'code': 0,
      'data': {'id': 7, 'title': '', 'attr': 2},
    });
    await settle(tester);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '完成'))
          .onPressed,
      isNotNull,
    );
    await finish(tester);
  });

  testWidgets('退出编辑页面后迟到查询不再写入已释放的文本框', (tester) async {
    await mount(tester);
    Get.toNamed('/create?mediaId=7');
    await tester.pump();
    await dispatched(tester, 1);
    Get.back();
    await settle(tester);
    requests[0].reply.complete({
      'code': 0,
      'data': {'id': 7, 'title': '迟到'},
    });
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('迟到'), findsNothing);
    await finish(tester);
  });
}
