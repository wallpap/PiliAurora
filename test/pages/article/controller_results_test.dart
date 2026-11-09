import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/models/remote/article/article_info/data.dart';
import 'package:pili_aurora/models/remote/article/article_view/data.dart';
import 'package:pili_aurora/models/remote/fav/fav_article/item.dart';
import 'package:pili_aurora/pages/article/controller.dart';
import 'package:pili_aurora/pages/fav/article/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _Article extends ArticleController {
  int repliesRequested = 0;
  @override
  bool get showDynActionBar => false;
  @override
  Future<void> queryData([bool isRefresh = true]) async {
    repliesRequested++;
  }
}

class _Favorites extends FavArticleController {
  final queries = <Future<void>>[];
  @override
  Future<void> queryData([bool isRefresh = true]) {
    final query = super.queryData(isRefresh);
    queries.add(query);
    return query;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor(
    headers: Headers.fromMap({
      'location': ['https://www.bilibili.com/opus/2'],
    }),
  );
  final requests = interceptor.requests;
  final controllers = <GetxController>[];
  late LoginAccount original;
  late LoginAccount heartbeat;
  LoginAccount account(int id, [String csrf = 'fixture']) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$id', 'bili_jct': csrf}),
    null,
    null,
  )..activated = true;
  T own<T extends GetxController>(T controller) {
    controllers.add(controller);
    return controller;
  }

  _Article article() => own(
    _Article()
      ..id = '1'
      ..type = 'read'
      ..commentId = 1,
  );
  Map<String, dynamic> opus(String title) => {
    'code': 0,
    'data': {
      'item': {
        'id_str': '1',
        'basic': {'comment_id_str': '1', 'comment_type': 12},
        'modules': [
          {
            'module_type': 'MODULE_TYPE_TITLE',
            'module_title': {'text': title},
          },
        ],
      },
    },
  };
  Map<String, dynamic> favorites(String id) => {
    'code': 0,
    'data': {
      'items': [
        {'opus_id': id},
      ],
      'has_more': false,
    },
  };
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() async {
    original = account(1, 'main');
    heartbeat = account(3, 'history');
    Accounts.accountMode[AccountType.main.index] = original;
    Accounts.accountMode[AccountType.heartbeat.index] = heartbeat;
    await GStorage.localCache.putAll({
      LocalCacheKey.mixinKey: 'synthetic',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    Get.parameters = {'id': '1', 'type': 'opus'};
    requests.clear();
  });
  tearDown(() {
    for (final controller in controllers.reversed) {
      if (!controller.isClosed) controller.onDelete();
    }
    controllers.clear();
    for (final request in requests) {
      if (!request.reply.isCompleted) {
        request.reply.complete({'code': -1, 'message': 'closed'});
      }
    }
    Get.reset();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> flush() => Future<void>.delayed(Duration.zero);
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

  Future<void> mount(WidgetTester tester) async {
    addTearDown(() async {
      final dismissal = SmartDialog.dismiss(status: .allToast);
      await tester.pumpAndSettle();
      await dismissal;
    });
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: SizedBox()),
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

  test('正文换凭据后拒绝旧结果，仅当前正文发起评论与所属账号的历史上报', () async {
    final controller = own(_Article())..onInit();
    await interceptor.waitForRequests(1);
    expect(requests.single.options.extra['account'], same(original));
    final replacement = account(1, 'replacement');
    Accounts.replaceCredentials(replacement);
    await interceptor.waitForRequests(2);
    expect(requests.last.options.extra['account'], same(replacement));
    requests.first.reply.complete(opus('旧文章'));
    await flush();
    expect(controller.isLoaded.value, isFalse);
    expect(controller.opusData, isNull);
    expect(controller.repliesRequested, 0);
    expect(requests, hasLength(2));
    requests.last.reply.complete(opus('新文章'));
    await interceptor.waitForRequests(3);
    expect(controller.isLoaded.value, isTrue);
    expect(controller.summary.title, '新文章');
    expect(controller.repliesRequested, 1);
    expect(requests.last.options.path, Api.historyReport);
    expect(requests.last.options.extra['account'], same(heartbeat));
    expect((requests.last.options.data as Map)['csrf'], heartbeat.csrf);
    requests.last.reply.complete({'code': 0});
    await flush();
    controller.onDelete();
    Accounts.replaceCredentials(account(1, 'closed'));
    expect(requests, hasLength(3));

    final report = VideoHttp.historyReport(aid: 1, type: 5);
    Accounts.accountMode[AccountType.heartbeat.index] = account(4);
    await interceptor.waitForRequests(4);
    expect(requests.last.options.extra['account'], same(heartbeat));
    expect((requests.last.options.data as Map)['csrf'], heartbeat.csrf);
    requests.last.reply.complete({'code': 0});
    await report;
  });

  test('文章正文校验目标并保留标题，关闭后的查询不发布内容', () async {
    final controller = article();
    var query = controller.queryRead(1);
    await interceptor.waitForRequests(1);
    requests.last.reply.complete({
      'code': 0,
      'data': {'id': 2, 'title': '错误目标'},
    });
    expect(await query, isFalse);
    expect(controller.loadingState.value.toString(), '文章与请求目标不符，请重试');
    query = controller.queryRead(1);
    await interceptor.waitForRequests(2);
    requests.last.reply.complete({
      'code': 0,
      'data': {'id': 1, 'title': '文章标题', 'content': '<p>正文</p>'},
    });
    expect(await query, isTrue);
    expect(controller.summary.title, '文章标题');
    expect(controller.images(), isEmpty);
    query = controller.queryRead(1);
    await interceptor.waitForRequests(3);
    controller.onDelete();
    requests.last.reply.complete({
      'code': 0,
      'data': {'id': 1, 'title': '已关闭'},
    });
    expect(await query, isFalse);
    expect(controller.articleData?.title, '文章标题');
  });

  test('文章本人点赞与总赞数独立，统计查询隔离换文章和关闭结果', () async {
    final controller = article();
    var query = controller.getArticleInfo();
    await interceptor.waitForRequests(1);
    requests.last.reply.complete({
      'code': 0,
      'data': {
        'like': 0,
        'stats': {'like': 1},
      },
    });
    expect(await query, isTrue);
    expect(controller.stats.value?.like?.count, 1);
    expect(controller.stats.value?.like?.status, isFalse);
    controller.stats.value = null;
    query = controller.getArticleInfo();
    await interceptor.waitForRequests(2);
    requests.last.reply.complete({
      'code': 0,
      'data': {
        'like': 1,
        'stats': {'like': 99},
      },
    });
    expect(await query, isTrue);
    expect(controller.stats.value?.like?.status, isTrue);
    expect(ArticleInfoData.fromJson({'like': true}).like, isTrue);
    expect(ArticleInfoData.fromJson({'like': false}).like, isFalse);
    final stats = controller.stats.value;
    query = controller.getArticleInfo();
    await interceptor.waitForRequests(3);
    controller
      ..id = '2'
      ..commentId = 2;
    requests.last.reply.complete({
      'code': 0,
      'data': {
        'title': '旧封面',
        'origin_image_urls': ['old'],
      },
    });
    expect(await query, isFalse);
    expect(controller.summary.cover, isNull);
    expect(controller.summary.title, isNull);
    expect(controller.stats.value, same(stats));
    query = controller.getArticleInfo();
    await interceptor.waitForRequests(4);
    controller.onDelete();
    requests.last.reply.complete({
      'code': 0,
      'data': {'title': '已关闭'},
    });
    expect(await query, isFalse);
    expect(controller.summary.title, isNull);
  });

  test('关闭文章后重定向不重新注册控制器或启动正文查询', () async {
    Get.parameters = {'id': '1', 'type': 'read'};
    final controller = own(_Article())..onInit();
    await interceptor.waitForRequests(1);
    expect(requests.single.options.method, 'HEAD');
    expect(controller.url, 'https://www.bilibili.com/read/cv1');
    controller.onDelete();
    requests.single.reply.complete('');
    await flush();
    expect(controller.id, '1');
    expect(controller.type, 'read');
    expect(Get.isRegistered<ArticleController>(tag: 'opus2'), isFalse);
    expect(requests, hasLength(1));
  });

  testWidgets('文章收藏防重复，待确认及换详情或切号均不错误改数', (tester) async {
    await mount(tester);
    final controller = article();
    final favorite = DynamicStat(count: 0, status: false);
    controller.stats.value = ModuleStatModel(favorite: favorite);
    var save = controller.onFav();
    await controller.onFav();
    await until(tester, () => requests.length == 1);
    expect(requests.single.options.path, Api.addFavArticle);
    expect(requests.single.options.extra['account'], same(original));
    requests.single.reply.complete({'code': '0'});
    await settle(tester);
    await save;
    expect(favorite.status, isFalse);
    expect(favorite.count, 0);
    expect(find.text('操作结果待确认，请先核对后再操作'), findsOneWidget);
    save = controller.onFav();
    await until(tester, () => requests.length == 2);
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await save;
    expect(favorite.status, isTrue);
    expect(favorite.count, 1);
    save = controller.onFav();
    await until(tester, () => requests.length == 3);
    expect(requests.last.options.path, Api.delFavArticle);
    final refreshed = DynamicStat(count: 8, status: true);
    controller.stats.value = ModuleStatModel(favorite: refreshed);
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await save;
    expect(favorite.count, 1);
    expect(refreshed.count, 8);
    save = controller.onFav();
    await until(tester, () => requests.length == 4);
    Accounts.accountMode[AccountType.main.index] = account(2);
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await save;
    expect(refreshed.count, 8);
    Accounts.accountMode[AccountType.main.index] = original;
    refreshed.count = null;
    final staleInfo = controller.getArticleInfo();
    await until(tester, () => requests.length == 5);
    final infoRequest = requests.last;
    save = controller.onFav();
    await until(tester, () => requests.length == 6);
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await save;
    expect(refreshed.status, isFalse);
    expect(refreshed.count, isNull);
    infoRequest.reply.complete({
      'code': 0,
      'data': {
        'favorite': true,
        'title': '收藏前的旧查询',
        'stats': {'favorite': 8},
      },
    });
    await settle(tester);
    expect(await staleInfo, isFalse);
    expect(controller.summary.title, isNull);
    expect(refreshed.status, isFalse);
    expect(refreshed.count, isNull);
    await finish(tester);
  });

  testWidgets('文章点赞缺少动态编号不发请求，拒绝或旧目标成功不修改计数', (tester) async {
    await mount(tester);
    final controller = article();
    final like = DynamicStat(count: 0, status: true);
    controller.stats.value = ModuleStatModel(like: like);
    await controller.onLike();
    await settle(tester);
    expect(requests, isEmpty);
    expect(find.text('暂未获取到文章动态编号，请刷新后重试'), findsOneWidget);
    controller.articleData = ArticleViewData(dynIdStr: '33');
    var save = controller.onLike();
    await controller.onLike();
    await until(tester, () => requests.length == 1);
    expect(requests.single.options.extra['account'], same(original));
    expect((requests.single.options.data as Map)['dyn_id_str'], '33');
    requests.single.reply.complete({'code': -667777, 'message': '拒绝点赞'});
    await settle(tester);
    await save;
    expect(like.count, 0);
    expect(like.status, isTrue);
    expect(find.text('拒绝点赞'), findsOneWidget);
    save = controller.onLike();
    await until(tester, () => requests.length == 2);
    controller.id = '2';
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await save;
    expect(like.status, isTrue);
    controller.opusData = DynamicItemModel.fromJson({'id_str': 34});
    save = controller.onLike();
    await until(tester, () => requests.length == 3);
    expect((requests.last.options.data as Map)['dyn_id_str'], '34');
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await save;
    expect(like.count, 0);
    expect(like.status, isFalse);
    like.count = null;
    final staleInfo = controller.getArticleInfo();
    await until(tester, () => requests.length == 4);
    final infoRequest = requests.last;
    save = controller.onLike();
    await until(tester, () => requests.length == 5);
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await save;
    expect(like.status, isTrue);
    expect(like.count, isNull);
    infoRequest.reply.complete({
      'code': 0,
      'data': {
        'like': 0,
        'title': '点赞前的旧查询',
        'stats': {'like': 9},
      },
    });
    await settle(tester);
    expect(await staleInfo, isFalse);
    expect(controller.summary.title, isNull);
    expect(like.status, isTrue);
    expect(like.count, isNull);
    await finish(tester);
  });

  test('文章收藏列表换凭据重载，旧结果不覆盖新列表并释放订阅', () async {
    final controller = own(_Favorites())..onInit();
    await interceptor.waitForRequests(1);
    final replacement = account(1, 'replacement');
    Accounts.replaceCredentials(replacement);
    await interceptor.waitForRequests(2);
    expect(requests.last.options.extra['account'], same(replacement));
    requests.last.reply.complete(favorites('2'));
    await controller.queries.last;
    requests.first.reply.complete(favorites('1'));
    await controller.queries.first;
    expect(controller.loadingState.value.data!.single.opusId, '2');
    controller.onDelete();
    Accounts.replaceCredentials(account(1, 'closed'));
    expect(requests, hasLength(2));
  });

  testWidgets('文章取消收藏防重复，待确认或列表替换保留条目，成功才移除', (tester) async {
    await mount(tester);
    final controller = own(FavArticleController());
    final list = [FavArticleItemModel(opusId: '1')];
    controller.loadingState.value = Success(list);
    var remove = controller.onRemove('1');
    await controller.onRemove('1');
    await until(tester, () => requests.length == 1);
    expect(requests.single.options.path, Api.communityAction);
    expect(requests.single.options.extra['account'], same(original));
    expect(requests.single.options.queryParameters['csrf'], original.csrf);
    requests.single.reply.complete({'code': '0'});
    await settle(tester);
    await remove;
    expect(list, hasLength(1));
    expect(find.text('操作结果待确认，请先核对后再操作'), findsOneWidget);
    remove = controller.onRemove('1');
    await until(tester, () => requests.length == 2);
    final refreshed = [FavArticleItemModel(opusId: '1')];
    controller.loadingState.value = Success(refreshed);
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await remove;
    expect(list, hasLength(1));
    expect(refreshed, hasLength(1));
    remove = controller.onRemove('1');
    await until(tester, () => requests.length == 3);
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await remove;
    expect(refreshed, isEmpty);
    expect(find.text('已取消收藏'), findsOneWidget);
    await finish(tester);
  });
}
