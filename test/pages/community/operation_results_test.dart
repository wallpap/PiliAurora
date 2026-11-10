import 'dart:async';

import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:pili_aurora/common/widgets/dialog/report.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/models/remote/emote/package.dart';
import 'package:pili_aurora/models/user/danmaku_rule.dart';
import 'package:pili_aurora/pages/common/publish/common_publish_page.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/emote/manage.dart';
import 'package:pili_aurora/pages/emote/preview.dart';
import 'package:pili_aurora/pages/dynamics_detail/controller.dart';
import 'package:pili_aurora/pages/video/reply/controller.dart';
import 'package:pili_aurora/pages/video/reply/widgets/zan_grpc.dart';
import 'package:pili_aurora/pages/video/send_danmaku/view.dart';
import 'package:pili_aurora/pages/video/widgets/header_control.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/reply_utils.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _Detail extends DynamicDetailController {
  int reloads = 0;
  @override
  Future<void> onReload() async {
    reloads++;
  }
}

class _Player implements PlPlayerController {
  @override
  int? cid = 1;
  @override
  RuleFilter filters = RuleFilter.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    GStorage.userInfo = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() {
    Accounts.accountMode[AccountType.main.index] = original;
    requests.clear();
  });
  tearDown(Get.reset);
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: Scaffold(body: child),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    await tester.pump();
  }

  Future<void> until(WidgetTester tester, bool Function() condition) async {
    final deadline = tester.binding.clock.now().add(const Duration(seconds: 3));
    while (!condition() && tester.binding.clock.now().isBefore(deadline)) {
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
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  ReplyInfo reply(int id) => ReplyInfo(
    id: Int64(id),
    oid: Int64(1),
    type: Int64.ONE,
    like: Int64(4),
  );

  testWidgets('评论赞踩共用在途状态，待确认保留计数并允许失败后重试', (tester) async {
    final item = reply(2);
    var updates = 0;
    await mount(
      tester,
      ZanButtonGrpc(replyItem: item, onUpdate: () => updates++),
    );
    final buttons = tester
        .widgetList<TextButton>(find.byType(TextButton))
        .toList();
    buttons[1].onPressed!();
    buttons[0].onPressed!();
    await until(tester, () => requests.length == 1);
    expect(
      tester
          .widgetList<TextButton>(find.byType(TextButton))
          .every((button) => button.onPressed == null),
      isTrue,
    );
    requests[0].reply.complete({'code': '0'});
    await settle(tester);
    expect(item.like, Int64(4));
    expect(item.replyControl.action, Int64.ZERO);
    expect(updates, 0);
    expect(find.text('操作结果待确认，请先核对后再操作'), findsOneWidget);
    await tester.tap(find.byType(TextButton).at(1));
    await until(tester, () => requests.length == 2);
    requests[1].reply.complete({'code': 0});
    await settle(tester);
    expect(item.like, Int64(5));
    expect(item.replyControl.action, Int64.ONE);
    expect(updates, 1);
    await finish(tester);
  });

  testWidgets('评论更换或切号后的迟到点赞结果不修改条目', (tester) async {
    final first = reply(2);
    final current = ValueNotifier(first);
    var updates = 0;
    await mount(
      tester,
      ValueListenableBuilder(
        valueListenable: current,
        builder: (_, item, _) =>
            ZanButtonGrpc(replyItem: item, onUpdate: () => updates++),
      ),
    );
    await tester.tap(find.byType(TextButton).at(1));
    await until(tester, () => requests.length == 1);
    current.value = reply(3);
    await tester.pump();
    requests[0].reply.complete({'code': 0});
    await settle(tester);
    expect(first.like, Int64(4));
    expect(current.value.like, Int64(4));
    await tester.tap(find.byType(TextButton).at(1));
    await until(tester, () => requests.length == 2);
    Accounts.accountMode[AccountType.main.index] = replacement;
    requests[1].reply.complete({'code': 0});
    await settle(tester);
    expect(current.value.like, Int64(4));
    expect(updates, 0);
    await finish(tester);
    current.dispose();
  });

  Future<CommonPublishPageState> openSender(
    WidgetTester tester,
    List<DanmakuContentItem<DanmakuExtra>> echoes,
    List<String> drafts,
  ) async {
    await mount(
      tester,
      TextButton(
        onPressed: () => Get.to(
          () => Scaffold(
            body: SendDanmakuPanel(
              cid: 1,
              bvid: 'BV1xx411c7mD',
              progress: 200,
              initialValue: '原弹幕',
              onSuccess: echoes.add,
              onSave: drafts.add,
            ),
          ),
        ),
        child: const Text('打开'),
      ),
    );
    await tester.tap(find.text('打开'));
    await settle(tester);
    return tester.state<CommonPublishPageState>(find.byType(SendDanmakuPanel));
  }

  testWidgets('弹幕按提交快照回显，等待时修改的新草稿保留在原页面', (tester) async {
    final echoes = <DanmakuContentItem<DanmakuExtra>>[];
    final drafts = <String>[];
    final state = await openSender(tester, echoes, drafts);
    final publish = state.onPublish();
    await state.onPublish();
    await until(tester, () => requests.length == 1);
    expect(requests.single.options.path, Api.shootDanmaku);
    state.editController.text = '新草稿';
    requests[0].reply.complete({'code': 0, 'data': <String, dynamic>{}});
    await settle(tester);
    await publish;
    expect(echoes.single.text, '原弹幕');
    expect(find.byType(SendDanmakuPanel), findsOneWidget);
    expect(state.editController.text, '新草稿');
    Get.back<void>();
    await settle(tester);
    expect(drafts.single, '新草稿');
    await finish(tester);
  });

  testWidgets('关闭发送面板后的迟到成功不回显也不关闭新页面', (tester) async {
    final echoes = <DanmakuContentItem<DanmakuExtra>>[];
    final drafts = <String>[];
    final state = await openSender(tester, echoes, drafts);
    final publish = state.onPublish();
    await until(tester, () => requests.length == 1);
    Get.back<void>();
    await settle(tester);
    Get.to<void>(() => const Scaffold(body: Text('新页面')));
    await settle(tester);
    requests[0].reply.complete({
      'code': 0,
      'data': {'dmid': 7},
    });
    await settle(tester);
    await publish;
    expect(echoes, isEmpty);
    expect(drafts.single, '原弹幕');
    expect(find.text('新页面'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('弹幕操作拒绝切号迟到结果，保留服务端已点赞纠正语义', (tester) async {
    await mount(tester, const SizedBox());
    final extra = VideoDanmaku(id: 2, mid: 'sender', like: 3);
    final like = HeaderControl.likeDanmaku(extra, 1);
    await until(tester, () => requests.length == 1);
    Accounts.accountMode[AccountType.main.index] = replacement;
    requests[0].reply.complete({'code': 0});
    await settle(tester);
    expect(await like, isFalse);
    expect(extra.isLike, isFalse);
    expect(extra.like, 3);
    final reconcile = HeaderControl.likeDanmaku(extra, 1);
    await until(tester, () => requests.length == 2);
    requests[1].reply.complete({'code': 65006});
    await settle(tester);
    expect(await reconcile, isTrue);
    expect(extra.isLike, isTrue);
    expect(extra.like, 3);
    await finish(tester);
  });

  testWidgets('表情包设置切号后显示可重试提示，旧数据不会进入页面', (tester) async {
    await mount(tester, const EmoteManagePage());
    await until(tester, () => requests.length == 1);
    Accounts.accountMode[AccountType.main.index] = replacement;
    requests[0].reply.complete({
      'code': 0,
      'data': {
        'user_panel_packages': [
          {'id': 1, 'text': '旧表情'},
        ],
      },
    });
    await settle(tester);
    expect(find.text('旧表情'), findsNothing);
    expect(find.text('账号已切换，请刷新重试'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('表情包移除待确认保留原列表且释放按钮', (tester) async {
    await mount(tester, const EmoteManagePage());
    await until(tester, () => requests.length == 1);
    requests[0].reply.complete({
      'code': 0,
      'data': {
        'user_panel_packages': [
          {'id': 1, 'text': '保留表情'},
        ],
      },
    });
    await until(tester, () => requests.length == 2);
    requests[1].reply.complete({
      'code': 0,
      'data': {'total': 0, 'packages': []},
    });
    await settle(tester);
    await tester.tap(find.byTooltip('移除'));
    await until(tester, () => requests.length == 3);
    requests[2].reply.complete({'code': '0'});
    await settle(tester);
    expect(find.text('保留表情'), findsOneWidget);
    expect(find.text('操作结果待确认，请先核对后再操作'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.remove))
          .onPressed,
      isNotNull,
    );
    await finish(tester);
  });

  testWidgets('表情包预览更换对象后只接受新详情', (tester) async {
    final current = ValueNotifier(Package(id: 1, text: '旧包'));
    await mount(
      tester,
      ValueListenableBuilder(
        valueListenable: current,
        builder: (_, package, _) => EmotePackagePreviewPage(package: package),
      ),
    );
    await until(tester, () => requests.length == 1);
    current.value = Package(id: 2, text: '新包');
    await until(tester, () => requests.length == 2);
    requests[1].reply.complete({
      'code': 0,
      'data': {
        'package': {
          'id': 2,
          'type': 4,
          'emote': [
            {'text': '新详情'},
          ],
        },
      },
    });
    await settle(tester);
    requests[0].reply.complete({
      'code': 0,
      'data': {
        'package': {
          'id': 1,
          'type': 4,
          'emote': [
            {'text': '旧详情'},
          ],
        },
      },
    });
    await settle(tester);
    expect(find.text('新详情'), findsOneWidget);
    expect(find.text('旧详情'), findsNothing);
    await finish(tester);
    current.dispose();
  });

  testWidgets('举报防止重复提交，取消后的迟到成功不关闭新页面', (tester) async {
    final reply = Completer<LoadingState>();
    var calls = 0;
    await mount(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => autoWrapReportDialog(
            context,
            const {
              '': {1: '垃圾内容'},
            },
            (_, _, _) {
              calls++;
              return reply.future;
            },
          ),
          child: const Text('举报入口'),
        ),
      ),
    );
    await tester.tap(find.text('举报入口'));
    await settle(tester);
    await tester.tap(find.text('垃圾内容'));
    await tester.pump();
    final submit = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '确定'))
        .onPressed!;
    submit();
    submit();
    await tester.pump();
    expect(calls, 1);
    expect(find.text('提交中'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settle(tester);
    Get.to<void>(() => const Scaffold(body: Text('新页面')));
    await settle(tester);
    reply.complete(const Success<void>(null));
    await settle(tester);
    expect(find.text('新页面'), findsOneWidget);
    expect(find.text('举报成功'), findsNothing);
    await finish(tester);
  });

  testWidgets('评论管理：置顶防重复，待确认保留列表，成功才调整置顶归属', (tester) async {
    await mount(tester, const SizedBox());
    final controller = VideoReplyController(
      aid: 1,
      videoType: .ugc,
      heroTag: 'top',
    );
    final first = reply(2);
    final second = reply(3);
    final list = [first, second];
    controller.loadingState.value = Success(list);
    final rejected = controller.onToggleTop(second, 1, 1, 1);
    await until(tester, () => requests.length == 1);
    await controller.onToggleTop(first, 0, 1, 1);
    expect(requests, hasLength(1));
    requests[0].reply.complete({'code': '0'});
    await settle(tester);
    await rejected;
    expect(controller.hasUpTop, isFalse);
    expect(list, [first, second]);
    final confirmed = controller.onToggleTop(second, 1, 1, 1);
    await until(tester, () => requests.length == 2);
    requests[1].reply.complete({'code': 0});
    await settle(tester);
    await confirmed;
    expect(controller.hasUpTop, isTrue);
    expect(list, [second, first]);
    expect(second.replyControl.isUpTop, isTrue);
    controller.onClose();
    await finish(tester);
  });

  testWidgets('评论管理：评论开关保留失败与成功文案，切号取消延迟刷新', (tester) async {
    await mount(tester, const SizedBox());
    final controller = _Detail()
      ..oid = 1
      ..replyType = 1
      ..dynItem = DynamicItemModel.fromJson({'id_str': '1'});
    final failed = controller.onSetReplySubject(1);
    await until(tester, () => requests.length == 1);
    await controller.onSetReplySubject(1);
    expect(requests, hasLength(1));
    requests[0].reply.complete({'code': -403, 'message': '设置被拒绝'});
    await settle(tester);
    await failed;
    expect(find.text('设置被拒绝'), findsOneWidget);
    final confirmed = controller.onSetReplySubject(1);
    await until(tester, () => requests.length == 2);
    requests[1].reply.complete({
      'code': 0,
      'data': {'action_toast': '评论已关闭'},
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await confirmed;
    Accounts.accountMode[AccountType.main.index] = replacement;
    await settle(tester);
    expect(find.text('评论已关闭'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.reloads, 0);
    controller.onClose();
    await finish(tester);
  });

  Future<void> checkReply(ReplyInfo item) => ReplyUtils.onCheckReply(
    replyInfo: item,
    biliSendCommAntifraud: false,
    sourceId: 1,
    isManual: true,
  );

  Future<void> mountReplyCheck(WidgetTester tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        navigatorObservers: [routeObserver],
        initialRoute: '/comments',
        getPages: [
          GetPage(
            name: '/comments',
            page: () => const Scaffold(body: Text('原评论页')),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('评论管理：离开再返回原页，迟到响应不继续查询或弹窗', (tester) async {
    await mountReplyCheck(tester);
    final action = checkReply(reply(2));
    await until(tester, () => requests.length == 1);
    Get.to<void>(() => const Scaffold(body: Text('其他页面')));
    await settle(tester);
    Get.back<void>();
    await settle(tester);
    requests[0].reply.complete({'code': 0, 'data': <String, dynamic>{}});
    await settle(tester);
    await action;
    expect(requests, hasLength(1));
    expect(find.byType(AlertDialog), findsNothing);
    await finish(tester);
  });

  testWidgets('评论管理：自动检查延迟期间离开后不发请求', (tester) async {
    await mountReplyCheck(tester);
    final action = ReplyUtils.onCheckReply(
      replyInfo: reply(2),
      biliSendCommAntifraud: false,
      sourceId: 1,
      isManual: false,
    );
    Get.to<void>(() => const Scaffold(body: Text('其他页面')));
    await settle(tester);
    Get.back<void>();
    await settle(tester);
    await tester.pump(const Duration(seconds: 8));
    await action;
    expect(requests, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    await finish(tester);
  });

  testWidgets('评论管理：发布页关闭后自动检查仍交付原评论页', (tester) async {
    await mountReplyCheck(tester);
    final sourceRoute = Get.routing.route;
    Get.to<void>(() => const Scaffold(body: Text('发布页')));
    await settle(tester);
    final action = ReplyUtils.onCheckReply(
      replyInfo: reply(2),
      biliSendCommAntifraud: false,
      sourceId: 1,
      isManual: false,
      sourceRoute: sourceRoute,
    );
    Get.back<void>();
    await settle(tester);
    await tester.pump(const Duration(seconds: 8));
    await until(tester, () => requests.length == 1);
    requests[0].reply.complete({
      'code': 0,
      'data': {
        'replies': [
          {'rpid': 2},
        ],
      },
    });
    await settle(tester);
    await action;
    expect(find.textContaining('无账号状态下找到了你的评论'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await settle(tester);
    expect(find.text('原评论页'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('评论管理：来源替换或账号切换不交付旧检查结果', (tester) async {
    await mountReplyCheck(tester);
    var current = true;
    final replaced = ReplyUtils.onCheckReply(
      replyInfo: reply(2),
      biliSendCommAntifraud: false,
      sourceId: 1,
      isManual: true,
      ownerIsCurrent: () => current,
    );
    await until(tester, () => requests.length == 1);
    current = false;
    requests[0].reply.complete({'code': -403, 'message': '旧来源查询失败'});
    await settle(tester);
    await replaced;
    final switched = checkReply(reply(2));
    await until(tester, () => requests.length == 2);
    Accounts.accountMode[AccountType.main.index] = replacement;
    requests[1].reply.complete({'code': -403, 'message': '旧账号查询失败'});
    await settle(tester);
    await switched;
    expect(find.textContaining('旧来源查询失败'), findsNothing);
    expect(find.textContaining('旧账号查询失败'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    await finish(tester);
  });

  testWidgets('评论管理：结果弹窗账号失效后申诉只关闭自己的弹窗', (tester) async {
    await mountReplyCheck(tester);
    final action = checkReply(reply(2));
    await until(tester, () => requests.length == 1);
    requests[0].reply.complete({'code': 0, 'data': <String, dynamic>{}});
    await until(tester, () => requests.length == 2);
    requests[1].reply.complete({'code': 12022, 'message': '不存在'});
    await settle(tester);
    await action;
    expect(find.text('申诉'), findsOneWidget);
    Accounts.accountMode[AccountType.main.index] = replacement;
    await tester.tap(find.text('申诉'));
    await settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('原评论页'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('评论管理：可见性查询故障和重复页不会误报 shadow ban', (tester) async {
    await mount(tester, const SizedBox());
    final item = reply(2)..root = Int64.ONE;
    final failed = checkReply(item);
    await until(tester, () => requests.length == 1);
    requests[0].reply.complete({'code': -403, 'message': '访问被拒绝'});
    await settle(tester);
    await failed;
    expect(find.text('评论检查失败：访问被拒绝'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    final repeated = checkReply(item);
    for (var i = 1; i <= 2; i++) {
      await until(tester, () => requests.length == i + 1);
      requests[i].reply.complete({
        'code': 0,
        'data': {
          'replies': [
            {'rpid': 3},
          ],
        },
      });
    }
    await settle(tester);
    await repeated;
    expect(requests, hasLength(3));
    expect(find.text('评论检查失败：评论列表未能继续加载，暂时无法确认评论状态'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    await finish(tester);
  });

  testWidgets('评论管理：明确 12022 业务码可确认仅自己可见', (tester) async {
    await mount(tester, const SizedBox());
    final action = checkReply(reply(2));
    for (var i = 0; i < 3; i++) {
      await until(tester, () => requests.length == i + 1);
      requests[i].reply.complete(
        i == 2
            ? {'code': 12022, 'message': '不可见'}
            : {'code': 0, 'data': <String, dynamic>{}},
      );
    }
    await settle(tester);
    await action;
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('你的评论被shadow ban'), findsOneWidget);
    Get.back<void>();
    await finish(tester);
  });

  testWidgets('弹幕举报成功与屏蔽同步待确认分别反馈，避免重发已成功举报', (tester) async {
    final player = _Player();
    await mount(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => HeaderControl.reportDanmaku(
            context,
            extra: VideoDanmaku(id: 7, mid: 'sender'),
            ctr: player,
          ),
          child: const Text('举报入口'),
        ),
      ),
    );
    await tester.tap(find.text('举报入口'));
    await settle(tester);
    await tester.tap(find.text('垃圾广告'));
    await tester.tap(find.text(' 拉黑该用户'));
    await tester.tap(find.text('确定'));
    await until(tester, () => requests.length == 1);
    expect(requests[0].options.path, Api.danmakuReport);
    requests[0].reply.complete({'code': 0});
    await until(tester, () => requests.length == 2);
    expect(requests[1].options.path, Api.danmakuFilterAdd);
    requests[1].reply.complete({'code': '0'});
    await settle(tester);
    expect(player.filters.dmUid, contains('sender'));
    expect(find.text('举报成功；屏蔽规则同步：操作结果待确认，请先核对后再操作'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(requests, hasLength(2));
    await finish(tester);
  });
}
