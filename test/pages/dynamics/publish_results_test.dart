import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/pages/common/publish/common_rich_text_pub_page.dart';
import 'package:pili_aurora/pages/dynamics_create/view.dart';
import 'package:pili_aurora/pages/dynamics_create_reserve/controller.dart';
import 'package:pili_aurora/pages/dynamics_create_vote/controller.dart';
import 'package:pili_aurora/pages/dynamics_repost/view.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/request_utils.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  Account account(int id) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$id', 'bili_jct': 'fixture-$id'}),
    null,
    null,
  );
  final original = account(1);
  final replacement = account(2);
  late Directory directory;
  late File image;
  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/shared_preferences'),
          (call) async => call.method == 'getAll' ? <String, Object>{} : true,
        );
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    GStorage.userInfo = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
    directory = await Directory.systemTemp.createTemp('pili-publish-');
    image = await File('${directory.path}/pixel.png').writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
      ),
    );
  });
  setUp(() {
    Accounts.accountMode[AccountType.main.index] = original;
    requests.clear();
  });
  tearDown(Get.reset);
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
    await image.delete();
    await directory.delete();
  });

  Future<void> mount(WidgetTester tester, [Widget? panel]) async {
    addTearDown(() async {
      final dismissal = SmartDialog.dismiss(status: .allToast);
      await tester.pumpAndSettle();
      await dismissal;
    });
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: Text('原页面')),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    if (panel != null) {
      Get.to(() => Scaffold(body: panel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }
  }

  Future<void> until(WidgetTester tester, bool Function() condition) async {
    final end = tester.binding.clock.now().add(const Duration(seconds: 3));
    while (!condition() && tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(condition(), isTrue);
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    final dismissal = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismissal;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  Object uploaded() => {
    'code': 0,
    'data': {
      'image_url': 'https://example.invalid/image.png',
      'image_width': 1,
      'image_height': 1,
    },
  };

  testWidgets('动态发布在图片上传前固定草稿，成功保留新草稿且阻止并发提交', (tester) async {
    var saved = 0;
    await mount(
      tester,
      CreateDynPanel(
        onSuccess: () {
          saved++;
          throw StateError('fixture callback');
        },
      ),
    );
    final state = tester.state<CommonRichTextPubPageState>(
      find.byType(CreateDynPanel),
    );
    state.editController.text = '原草稿';
    state.imageList.add(FilePicModel(path: image.path));
    late Future<void> pending;
    await tester.runAsync(() async {
      pending = state.onPublish();
      await state.onPublish();
      await interceptor.waitForRequests(1);
    });
    expect(requests.single.options.path, Api.uploadBfs);
    state.editController.text = '新草稿';
    state.imageList.clear();
    await tester.runAsync(() async {
      requests[0].reply.complete(uploaded());
      await interceptor.waitForRequests(2);
    });
    final body = requests[1].options.data as Map;
    expect(body['dyn_req']['content']['contents'].first['raw_text'], '原草稿');
    expect(body['dyn_req']['pics'], hasLength(1));
    await tester.runAsync(() async {
      requests[1].reply.complete({'code': 0});
      await pending;
    });
    await settle(tester);
    expect(saved, 1);
    expect(state.editController.text, '新草稿');
    expect(state.hasPub, isFalse);
    expect(find.byType(CreateDynPanel), findsOneWidget);
    expect(find.text('发布成功，已保留新草稿'), findsOneWidget);
    expect(find.text('发布准备失败，请重试'), findsNothing);
    await finish(tester);
  });

  testWidgets('动态上传后切号不继续发布，待确认保留草稿并释放提交状态', (tester) async {
    await mount(tester, const CreateDynPanel());
    final state = tester.state<CommonRichTextPubPageState>(
      find.byType(CreateDynPanel),
    );
    state.editController.text = '草稿';
    state.imageList.add(FilePicModel(path: image.path));
    late Future<void> uploading;
    await tester.runAsync(() async {
      uploading = state.onPublish();
      await interceptor.waitForRequests(1);
    });
    Accounts.accountMode[AccountType.main.index] = replacement;
    await tester.runAsync(() async {
      requests[0].reply.complete(uploaded());
      await uploading;
    });
    await settle(tester);
    expect(requests, hasLength(1));
    state.imageList.clear();
    final saving = state.onPublish();
    await until(tester, () => requests.length == 2);
    requests[1].reply.complete({'code': '0'});
    await settle(tester);
    await saving;
    expect(state.editController.text, '草稿');
    expect(find.text('操作结果待确认，请先核对后再操作'), findsOneWidget);
    expect(find.text('发布中'), findsNothing);
    await finish(tester);
  });

  testWidgets('转发成功和迟到失败不会关闭之后打开的页面', (tester) async {
    await mount(tester, const RepostPanel(dynIdStr: '1'));
    final state = tester.state<CommonRichTextPubPageState>(
      find.byType(RepostPanel),
    );
    state.editController.text = '转发内容';
    final pending = state.onPublish();
    await until(tester, () => requests.length == 1);
    Get.to(() => const Scaffold(body: Text('新页面')), preventDuplicates: false);
    await settle(tester);
    requests[0].reply.complete({'code': 0});
    await settle(tester);
    await pending;
    expect(find.text('新页面'), findsOneWidget);
    Get.back();
    await settle(tester);
    final second = state.onPublish();
    await until(tester, () => requests.length == 2);
    Accounts.accountMode[AccountType.main.index] = replacement;
    requests[1].reply.complete({'code': -403, 'message': '旧转发失败'});
    await settle(tester);
    await second;
    expect(find.text('旧转发失败'), findsNothing);
    await finish(tester);
  });

  testWidgets('投票保存互斥并返回提交时的选项副本，待确认后允许核对再操作', (tester) async {
    await mount(tester);
    final controller = CreateVoteController(null)..onInit();
    addTearDown(controller.onDelete.call);
    controller.title.value = '原标题';
    controller.options[0].optDesc = '甲';
    controller.options[1].optDesc = '乙';
    final pending = controller.onCreate();
    expect(await controller.onCreate(), isA<Error>());
    await until(tester, () => requests.length == 1);
    controller.title.value = '新标题';
    controller.options[0].optDesc = '新选项';
    requests[0].reply.complete({
      'code': 0,
      'data': {'vote_id': 7},
    });
    await settle(tester);
    final result = await pending;
    expect(result.data.title, '原标题');
    expect(result.data.options.first.optDesc, '甲');
    expect(result.data.voteId, 7);
    expect(controller.title.value, '新标题');
    final retry = controller.onCreate();
    await until(tester, () => requests.length == 2);
    requests[1].reply.complete({'code': '0'});
    await settle(tester);
    expect(await retry, isA<UnknownResult>());
    expect(controller.saving.value, isFalse);
    await finish(tester);
  });

  testWidgets('预约保存返回提交快照，切号或关闭后不交付旧成功结果', (tester) async {
    await mount(tester);
    final controller = CreateReserveController(null)..onInit();
    controller.title.value = '原预约';
    final pending = controller.onCreate();
    expect(await controller.onCreate(), isA<Error>());
    await until(tester, () => requests.length == 1);
    controller.title.value = '新预约';
    requests[0].reply.complete({
      'code': 0,
      'data': {'sid': 7},
    });
    await settle(tester);
    expect((await pending).data.title, '原预约');
    final stale = controller.onCreate();
    await until(tester, () => requests.length == 2);
    controller.onDelete();
    requests[1].reply.complete({
      'code': 0,
      'data': {'sid': 8},
    });
    await settle(tester);
    expect(await stale, isA<Error>());
    final switched = CreateVoteController(null)..onInit();
    addTearDown(switched.onDelete.call);
    Accounts.accountMode[AccountType.main.index] = replacement;
    expect(await switched.onCreate(), isA<Error>());
    expect(requests, hasLength(2));
    await finish(tester);
  });

  testWidgets('投票与预约详情失败可重试，关闭后拒绝迟到的必需字段', (tester) async {
    await mount(tester);
    final vote = CreateVoteController(7)..onInit();
    final reserve = CreateReserveController(8)..onInit();
    await until(tester, () => requests.length == 2);
    for (final request in requests) {
      request.reply.complete({'code': -403, 'message': '加载失败'});
    }
    await settle(tester);
    expect(vote.loadError.value?.code, -403);
    expect(reserve.loadError.value?.code, -403);
    expect(vote.canCreate.value, isFalse);
    expect(reserve.canCreate.value, isFalse);
    final retry = reserve.queryData();
    await until(tester, () => requests.length == 3);
    requests[2].reply.complete({
      'code': 0,
      'data': {'id': 8, 'title': '预约', 'live_plan_start_time': 1900000000},
    });
    await settle(tester);
    await retry;
    expect(reserve.title.value, '预约');
    expect(reserve.canCreate.value, isTrue);
    final stale = vote.queryData();
    await until(tester, () => requests.length == 4);
    vote.onDelete();
    requests[3].reply.complete({'code': -403, 'message': '旧错误'});
    await settle(tester);
    await stale;
    expect(vote.loadError.value, isNull);
    reserve.onDelete();
    await finish(tester);
  });

  testWidgets('动态可见性查询故障只报告无法确认，不误报仅自己可见', (tester) async {
    await mount(tester);
    final pending = RequestUtils.checkCreatedDyn(id: '1', isManual: true);
    await until(tester, () => requests.length == 1);
    requests.single.reply.complete({'code': -500, 'message': '服务暂不可用'});
    await settle(tester);
    await pending;
    expect(find.textContaining('暂时无法确认动态可见性'), findsOneWidget);
    expect(find.textContaining('shadow ban'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    await finish(tester);
  });
}
