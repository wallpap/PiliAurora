import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/grpc/bilibili/app/dynamic/v2.pb.dart'
    show LikeListReply, ModuleAuthor, RepostListRsp, DynamicItem, Extend;
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/pages/common/dyn/like_list/controller.dart';
import 'package:pili_aurora/pages/common/dyn/repost_list/controller.dart';
import 'package:pili_aurora/pages/dynamics/controller.dart';
import 'package:pili_aurora/pages/dynamics/widgets/author_panel.dart';
import 'package:pili_aurora/pages/dynamics_tab/controller.dart';
import 'package:pili_aurora/services/account_service.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _Overview extends DynamicsController {
  DynamicsTabController? child;
  final queries = <Future<void>>[];
  @override
  DynamicsTabController? get controller => child;
  @override
  Future<void> queryData([bool isRefresh = true]) {
    final query = super.queryData(isRefresh);
    queries.add(query);
    return query;
  }
}

class _Child extends GetxController implements DynamicsTabController {
  final refreshResult = Completer<void>();
  @override
  Future<void> onRefresh() => refreshResult.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor(
    headers: Headers.fromMap({
      'grpc-status': ['0'],
    }),
  );
  final requests = interceptor.requests;
  final controllers = <GetxController>[];
  late LoginAccount original;
  LoginAccount account([String csrf = 'fixture']) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': csrf}),
    null,
    null,
  )..activated = true;
  T own<T extends GetxController>(T controller) {
    controllers.add(controller);
    return controller;
  }

  Map<String, dynamic> ups(List<int> ids, [String offset = 'next']) => {
    'code': 0,
    'data': {
      'up_list': {
        'items': ids.map((id) => {'mid': id}).toList(),
        'has_more': true,
        'offset': offset,
      },
    },
  };
  DynamicItemModel item({bool withSource = true}) => DynamicItemModel.fromJson({
    'id_str': '12',
    if (withSource) 'basic': {'comment_id_str': '34', 'comment_type': 11},
    'modules': {
      'module_author': {'mid': 1, 'name': '作者'},
    },
  });
  Map<String, dynamic> interaction() => {
    'code': 0,
    'data': {
      'up_reply_selection': {'status': 0, 'can_modify': true},
      'up_reply': {'status': 1, 'can_modify': true},
    },
  };

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
  setUp(() async {
    original = account();
    Accounts.accountMode[AccountType.main.index] = original;
    await GStorage.setting.put(SettingBoxKey.dynamicsShowAllFollowedUp, false);
    Get.put(AccountService());
    requests.clear();
  });
  tearDown(() {
    for (final controller in controllers.reversed) {
      if (!controller.isClosed) controller.onDelete();
    }
    controllers.clear();
    Get.reset();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

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

  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: Scaffold(body: child),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
  }

  Future<void> finish(WidgetTester tester) async {
    final dismissal = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismissal;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  Future<void> menu(
    WidgetTester tester,
    DynamicItemModel dynamicItem, {
    ValueChanged<int>? onSetReplySubject,
  }) async {
    await mount(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => AuthorPanel(
            item: dynamicItem,
            onSetReplySubject: onSetReplySubject,
          ).morePanel(context),
          child: const Text('菜单'),
        ),
      ),
    );
    await tester.tap(find.text('菜单'));
    await settle(tester);
  }

  testWidgets('聚合页凭据替换刷新并拒绝旧结果，释放后停止订阅', (tester) async {
    final controller = own(_Overview())..onStart();
    await until(tester, () => requests.length == 1);
    final replacement = account('new');
    Accounts.replaceCredentials(replacement);
    await until(tester, () => requests.length == 2);
    expect(requests[0].options.extra['account'], same(original));
    expect(requests[1].options.extra['account'], same(replacement));
    requests[1].reply.complete(ups([2]));
    await controller.queries[1];
    requests[0].reply.complete(ups([1]));
    await controller.queries[0];
    expect(controller.loadingState.value.data.upList!.single.mid, 2);
    controller.onDelete();
    Accounts.replaceCredentials(account('third'));
    await tester.pump();
    expect(requests, hasLength(2));
  });

  testWidgets('聚合页刷新等待两个面板，分页游标停滞不追加重复数据', (tester) async {
    final controller = own(_Overview())..onStart();
    await until(tester, () => requests.length == 1);
    requests[0].reply.complete(ups([1]));
    await controller.queries[0];
    final child = _Child();
    controller.child = child;
    var completed = false;
    final refresh = controller.onRefresh().then((_) => completed = true);
    await until(tester, () => requests.length == 2);
    child.refreshResult.complete();
    await tester.pump();
    expect(completed, isFalse);
    requests[1].reply.complete(ups([2]));
    await refresh;
    final more = controller.onLoadMore();
    await until(tester, () => requests.length == 3);
    requests[2].reply.complete({
      'code': 0,
      'data': (ups([2])['data'] as Map)['up_list'],
    });
    await more;
    expect(controller.loadingState.value.data.upList, hasLength(1));
    await controller.onLoadMore();
    expect(requests, hasLength(3));
  });

  testWidgets('全部关注分页持续去重，页码只在成功后推进', (tester) async {
    await GStorage.setting.put(SettingBoxKey.dynamicsShowAllFollowedUp, true);
    final controller = own(_Overview())..onStart();
    await until(tester, () => requests.length == 1);
    requests[0].reply.complete(ups([1]));
    await controller.queries[0];
    for (var page = 1; page <= 2; page++) {
      final more = controller.onLoadMore();
      await until(tester, () => requests.length == page + 1);
      expect(requests.last.options.queryParameters['pn'], page);
      requests.last.reply.complete({
        'code': 0,
        'data': {
          'list': [
            for (final id in [1, 2, page + 2]) {'mid': id},
          ],
        },
      });
      await more;
    }
    expect(controller.loadingState.value.data.upList!.map((e) => e.mid), [
      1,
      2,
      3,
      4,
    ]);
  });

  for (final likes in [true, false]) {
    testWidgets('${likes ? '点赞' : '转发'}列表固定账号并淘汰旧结果，重复游标终止分页', (tester) async {
      final controller = own(
        likes ? DynLikeController('12') : DynRepostController('12'),
      );
      controller.onStart();
      // 两类列表共享查询生命周期，响应仍使用各自的 protobuf 模型。
      Future<void> query() => likes
          ? (controller as DynLikeController).queryData()
          : (controller as DynRepostController).queryData();
      dynamic response(int id) => GrpcReq.compressProtobuf(
        likes
            ? LikeListReply(
                totalCount: Int64(5),
                hasMore: true,
                list: [ModuleAuthor(mid: Int64(id))],
              ).writeToBuffer()
            : RepostListRsp(
                totalCount: Int64(5),
                hasMore: true,
                offset: '$id',
                list: [DynamicItem(extend: Extend(dynIdStr: '$id'))],
              ).writeToBuffer(),
      );
      final old = query();
      await until(tester, () => requests.length == 1);
      final replacement = account('new');
      Accounts.replaceCredentials(replacement);
      await until(tester, () => requests.length == 2);
      expect(requests[1].options.extra['account'], same(replacement));
      requests[1].reply.complete(response(2));
      await until(
        tester,
        () => likes
            ? !(controller as DynLikeController).isLoading
            : !(controller as DynRepostController).isLoading,
      );
      requests[0].reply.complete(response(1));
      await old;
      final more = likes
          ? (controller as DynLikeController).onLoadMore()
          : (controller as DynRepostController).onLoadMore();
      await until(tester, () => requests.length == 3);
      requests[2].reply.complete(response(2));
      await more;
      if (likes) {
        final list = controller as DynLikeController;
        expect(list.loadingState.value.data!.single.mid, Int64(2));
        expect(list.isEnd, isTrue);
        await list.onLoadMore();
      } else {
        final list = controller as DynRepostController;
        expect(list.loadingState.value.data!.single.extend.dynIdStr, '2');
        expect(list.isEnd, isTrue);
        await list.onLoadMore();
      }
      expect(requests, hasLength(3));
    });
  }

  testWidgets('互动设置缺少评论来源时不请求，切号后的旧查询不弹窗', (tester) async {
    await menu(tester, item(withSource: false), onSetReplySubject: (_) {});
    await tester.tap(find.text('互动设置'));
    await settle(tester);
    expect(requests, isEmpty);
    expect(find.text('动态缺少有效的评论来源，请刷新后重试'), findsOneWidget);
    await finish(tester);
    await menu(tester, item(), onSetReplySubject: (_) {});
    await tester.tap(find.text('互动设置'));
    await until(tester, () => requests.length == 1);
    expect(requests.single.options.extra['account'], same(original));
    Accounts.accountMode[AccountType.main.index] = account('new');
    requests.single.reply.complete(interaction());
    await settle(tester);
    expect(find.text('开启评论精选'), findsNothing);
    await finish(tester);
  });

  testWidgets('互动设置弹窗切号后不调用旧写入回调', (tester) async {
    final actions = <int>[];
    await menu(tester, item(), onSetReplySubject: actions.add);
    await tester.tap(find.text('互动设置'));
    await until(tester, () => requests.length == 1);
    requests.single.reply.complete(interaction());
    await settle(tester);
    expect(find.text('开启评论精选'), findsOneWidget);
    Accounts.accountMode[AccountType.main.index] = account('new');
    await tester.tap(find.text('开启评论精选'));
    await settle(tester);
    expect(actions, isEmpty);
    await finish(tester);
  });

  testWidgets('动态举报确认成功后才拉黑，部分失败保留举报成功', (tester) async {
    await menu(tester, item());
    await tester.tap(find.text('举报'));
    await settle(tester);
    await tester.tap(find.text('垃圾广告'));
    await tester.tap(find.textContaining('拉黑该用户'));
    await tester.tap(find.text('确定'));
    await until(tester, () => requests.length == 1);
    expect(requests[0].options.path, Api.dynamicReport);
    requests[0].reply.complete({'code': -403, 'message': '拒绝'});
    await settle(tester);
    expect(requests, hasLength(1));
    await tester.tap(find.text('确定'));
    await until(tester, () => requests.length == 2);
    requests[1].reply.complete({'code': 0});
    await until(tester, () => requests.length == 3);
    expect(requests[2].options.path, Api.relationMod);
    expect(requests[2].options.extra['account'], same(original));
    expect(requests[2].options.extra['noRetry'], isTrue);
    requests[2].reply.complete({'code': '0'});
    await settle(tester);
    expect(find.textContaining('举报成功；拉黑用户：操作结果待确认'), findsOneWidget);
    expect(find.text('请选择举报的理由：'), findsNothing);
    await finish(tester);
  });

  testWidgets('动态举报切号后的迟到成功不拉黑或提示当前账号', (tester) async {
    await menu(tester, item());
    await tester.tap(find.text('举报'));
    await settle(tester);
    await tester.tap(find.text('垃圾广告'));
    await tester.tap(find.textContaining('拉黑该用户'));
    await tester.tap(find.text('确定'));
    await until(tester, () => requests.length == 1);
    Accounts.accountMode[AccountType.main.index] = account('new');
    requests.single.reply.complete({'code': 0});
    await settle(tester);
    expect(requests, hasLength(1));
    expect(find.text('举报成功'), findsNothing);
    expect(find.text('请选择举报的理由：'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settle(tester);
    await finish(tester);
  });
}
