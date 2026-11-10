import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/home_tab_type.dart';
import 'package:pili_aurora/models/common/pgc_review_type.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_review/list.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_review/stat.dart';
import 'package:pili_aurora/pages/pgc/controller.dart';
import 'package:pili_aurora/pages/pgc_review/child/controller.dart';
import 'package:pili_aurora/pages/pgc_review/child/view.dart';
import 'package:pili_aurora/pages/pgc_review/post/view.dart';
import 'package:pili_aurora/services/account_service.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  final controllers = <GetxController>[];
  LoginAccount account(int id) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$id', 'bili_jct': 'fixture-$id'}),
    null,
    null,
  );
  late Account original;
  T own<T extends GetxController>(T controller) {
    controllers.add(controller);
    return controller;
  }

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
    original = account(1);
    Accounts.accountMode[AccountType.main.index] = original;
    requests.clear();
    Get.put(AccountService());
  });
  tearDown(() {
    for (final controller in controllers) {
      controller.onDelete();
    }
    controllers.clear();
    Get.reset();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  Map<String, dynamic> timeline(List<int> days) => {
    'code': 0,
    'result': [
      for (final day in days)
        {'date_ts': day, 'date': 'day-$day', 'day_of_week': 1, 'episodes': []},
    ],
  };
  Map<String, dynamic> reviews(List<int> ids, String next) => {
    'code': 0,
    'data': {
      'list': [
        for (final id in ids) {'review_id': id},
      ],
      'next': next,
      'count': 10,
    },
  };

  test('时间表失败可重试，部分成功保留提示，按日期合并不依赖两侧长度', () async {
    final controller = own(PgcController(tabType: HomeTabType.bangumi));
    var pending = controller.queryPgcTimeline();
    await interceptor.waitForRequests(2);
    for (final request in requests) {
      request.reply.complete({'code': -403, 'message': '拒绝请求'});
    }
    await pending;
    expect(controller.timelineState.value, isA<Error>());
    pending = controller.queryPgcTimeline();
    await interceptor.waitForRequests(4);
    requests[2].reply.complete(timeline([2]));
    requests[3].reply.complete({'code': -403});
    await pending;
    expect(controller.timelineState.value.data!.single.dateTs, 2);
    expect(controller.timelineWarning.value, isNotNull);
    pending = controller.queryPgcTimeline();
    await interceptor.waitForRequests(6);
    requests[4].reply.complete(timeline([2, 3]));
    requests[5].reply.complete(timeline([1, 2, 3]));
    await pending;
    expect(controller.timelineState.value.data!.map((day) => day.dateTs), [
      1,
      2,
      3,
    ]);
    expect(controller.timelineWarning.value, isNull);
    expect(
      requests.every((r) => identical(r.options.extra['account'], original)),
      isTrue,
    );
  });

  test('时间表刷新乱序和关闭后的迟到结果不能覆盖当前快照', () async {
    final controller = own(PgcController(tabType: HomeTabType.bangumi));
    final old = controller.queryPgcTimeline();
    await interceptor.waitForRequests(2);
    final latest = controller.queryPgcTimeline();
    await interceptor.waitForRequests(4);
    requests[2].reply.complete(timeline([2]));
    requests[3].reply.complete(timeline([]));
    await latest;
    requests[0].reply.complete(timeline([1]));
    requests[1].reply.complete(timeline([]));
    await old;
    expect(controller.timelineState.value.data!.single.dateTs, 2);
    final closing = controller.queryPgcTimeline();
    await interceptor.waitForRequests(6);
    controller.onDelete();
    requests[4].reply.complete(timeline([3]));
    requests[5].reply.complete(timeline([]));
    await closing;
    expect(controller.timelineState.value.data!.single.dateTs, 2);
  });

  test('短评查询绑定账号，重复游标停止且不追加重复点评', () async {
    final controller = own(
      PgcReviewController(type: PgcReviewType.short, mediaId: 1),
    );
    final old = controller.queryData();
    await interceptor.waitForRequests(1);
    final replacement = account(2);
    Accounts.accountMode[AccountType.main.index] = replacement;
    final latest = controller.onReload();
    await interceptor.waitForRequests(2);
    requests[1].reply.complete(reviews([2], 'next'));
    await latest;
    requests[0].reply.complete(reviews([1], 'old'));
    await old;
    expect(controller.loadingState.value.data!.single.reviewId, 2);
    final more = controller.onLoadMore();
    await interceptor.waitForRequests(3);
    expect(requests.last.options.extra['account'], same(replacement));
    expect(requests.last.options.queryParameters['cursor'], 'next');
    requests.last.reply.complete(reviews([2, 3], 'next'));
    await more;
    expect(controller.loadingState.value.data!.map((item) => item.reviewId), [
      2,
      3,
    ]);
    expect(controller.isEnd, isTrue);
  });

  test('赞踩共用单项写入锁，未知计数保留，旧列表结果不回写', () async {
    final controller = own(
      PgcReviewController(type: PgcReviewType.short, mediaId: 1),
    );
    final item = PgcReviewItemModel(
      reviewId: 2,
      score: 4,
      stat: Stat(liked: 1),
    );
    controller.loadingState.value = Success([item]);
    final dislike = controller.onDislike(item);
    await interceptor.waitForRequests(1);
    await controller.onLike(item);
    expect(requests, hasLength(1));
    expect(item.stat!.disliked, isNull);
    requests[0].reply.complete({'code': 0});
    await dislike;
    expect(item.stat!.liked, 0);
    expect(item.stat!.disliked, 1);
    expect(item.stat!.likes, isNull);
    final like = controller.onLike(item);
    await interceptor.waitForRequests(2);
    controller.loadingState.value = const Success([]);
    requests[1].reply.complete({'code': 0});
    await like;
    expect(item.stat!.liked, 0);
    expect(controller.pendingReviews, isEmpty);
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: Text('原页面')),
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

  testWidgets('点评缺少可选作者、内容和统计时仍可展示', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        const GetMaterialApp(
          home: Scaffold(
            body: PgcReviewChildPage(
              type: PgcReviewType.short,
              name: '作品',
              mediaId: 1,
            ),
          ),
        ),
      );
      await interceptor.waitForRequests(1);
      requests.single.reply.complete({
        'code': 0,
        'data': {
          'list': [<String, dynamic>{}],
        },
      });
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('匿名用户'), findsOneWidget);
    expect(find.text('赞'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('删除失败保留点评及数量，切号后迟到成功不修改旧列表', (tester) async {
    await mount(tester);
    final controller = own(
      PgcReviewController(type: PgcReviewType.short, mediaId: 1),
    );
    final item = PgcReviewItemModel(reviewId: 2, score: 4);
    controller.loadingState.value = Success([item]);
    controller.count.value = 1;
    await tester.runAsync(() async {
      final pending = controller.onDel(2);
      await interceptor.waitForRequests(1);
      await controller.onDel(2);
      requests[0].reply.complete({'code': -403, 'message': '拒绝删除'});
      await pending;
    });
    expect(controller.loadingState.value.data, [item]);
    expect(controller.count.value, 1);
    await tester.runAsync(() async {
      final pending = controller.onDel(2);
      await interceptor.waitForRequests(2);
      Accounts.accountMode[AccountType.main.index] = account(2);
      requests[1].reply.complete({'code': 0});
      await pending;
    });
    expect(controller.loadingState.value.data, [item]);
    expect(controller.count.value, 1);
    await finish(tester);
  });

  Future<void> openPost(WidgetTester tester) async {
    showModalBottomSheet<void>(
      context: tester.element(find.text('原页面')),
      isScrollControlled: true,
      builder: (_) => const PgcReviewPostPanel(
        name: '作品',
        mediaId: 1,
        reviewId: 2,
        score: 4,
        content: '原草稿',
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('点评提交固定草稿并禁用重复提交，成功保留后来编辑的草稿', (tester) async {
    await mount(tester);
    await openPost(tester);
    await tester.runAsync(() async {
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed!();
      await interceptor.waitForRequests(1);
    });
    await tester.pump();
    expect(find.text('提交中…'), findsOneWidget);
    expect((requests.single.options.data as Map)['content'], '原草稿');
    expect(requests.single.options.extra['account'], same(original));
    await tester.enterText(find.byType(TextField), '新草稿');
    requests.single.reply.complete({'code': 0});
    await tester.pumpAndSettle();
    expect(find.byType(PgcReviewPostPanel), findsOneWidget);
    expect(find.text('新草稿'), findsOneWidget);
    expect(requests, hasLength(1));
    Navigator.of(tester.element(find.byType(PgcReviewPostPanel))).pop();
    await finish(tester);
  });

  testWidgets('关闭点评面板后的迟到成功不关闭后来打开的页面', (tester) async {
    await mount(tester);
    await openPost(tester);
    await tester.runAsync(() async {
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed!();
      await interceptor.waitForRequests(1);
    });
    Navigator.of(tester.element(find.byType(PgcReviewPostPanel))).pop();
    await tester.pumpAndSettle();
    Get.to(() => const Scaffold(body: Text('新页面')));
    await tester.pumpAndSettle();
    requests.single.reply.complete({'code': 0});
    await tester.pumpAndSettle();
    expect(find.text('新页面'), findsOneWidget);
    expect(requests.single.options.path, Api.pgcReviewMod);
    await finish(tester);
  });
}
