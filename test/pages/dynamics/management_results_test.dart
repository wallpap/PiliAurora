import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/dynamic/dynamics_type.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_mention/item.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_feed/fold_card_item.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_feed/item.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_top/top_details.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_top/topic_item.dart';
import 'package:pili_aurora/pages/dynamics/controller.dart';
import 'package:pili_aurora/pages/dynamics_mention/controller.dart';
import 'package:pili_aurora/pages/dynamics_select_topic/controller.dart';
import 'package:pili_aurora/pages/dynamics_tab/controller.dart';
import 'package:pili_aurora/pages/dynamics_topic/controller.dart';
import 'package:pili_aurora/pages/member_dynamics/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _Dynamics extends GetxController implements DynamicsController {
  @override
  int hostMid = 1;
  @override
  final tempBannedList = <int>{};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Member extends MemberDynamicsController {
  _Member() : super(1);
  final queries = <Future<void>>[];
  @override
  Future<void> queryData([bool isRefresh = true]) {
    final query = super.queryData(isRefresh);
    queries.add(query);
    return query;
  }
}

class _Tab extends DynamicsTabController {
  _Tab() : super(dynamicsType: .up);
  final queries = <Future<void>>[];
  @override
  Future<void> queryData([bool isRefresh = true]) {
    final query = super.queryData(isRefresh);
    queries.add(query);
    return query;
  }
}

class _Topic extends DynTopicController {
  final queries = <Future<void>>[];
  final tops = <Future<void>>[];
  @override
  Future<void> queryData([bool isRefresh = true]) {
    final query = super.queryData(isRefresh);
    queries.add(query);
    return query;
  }

  @override
  Future<void> queryTop() {
    final query = super.queryTop();
    tops.add(query);
    return query;
  }
}

class _Selection extends SelectTopicController {
  final queries = <Future<void>>[];
  @override
  Future<void> queryData([bool isRefresh = true]) {
    final query = super.queryData(isRefresh);
    queries.add(query);
    return query;
  }
}

class _Mentions extends DynMentionController {
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
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  LoginAccount account(int id, [String csrf = 'fixture']) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$id', 'bili_jct': csrf}),
    null,
    null,
  )..activated = true;
  late LoginAccount original;
  late LoginAccount recommend;
  final controllers = <GetxController>[];

  T own<T extends GetxController>(T controller) {
    controllers.add(controller);
    return controller;
  }

  DynamicItemModel item(String id) => DynamicItemModel.fromJson({'id_str': id});
  Map<String, dynamic> dynamics(String id) => {
    'code': 0,
    'data': {
      'has_more': false,
      'offset': id,
      'items': [
        {'id_str': id},
      ],
    },
  };
  TopicItem topic([String name = '话题']) => TopicItem(
    id: 12,
    name: name,
    view: 0,
    discuss: 0,
    fav: 2,
    like: 3,
  );
  Map<String, dynamic> top(String name) => {
    'code': 0,
    'data': {
      'top_details': {
        'topic_item': {'id': 12, 'name': name},
      },
    },
  };
  Map<String, dynamic> feed(String id) => {
    'code': 0,
    'data': {
      'topic_card_list': {
        'has_more': false,
        'items': [
          {
            'dynamic_card_item': {'id_str': id},
          },
        ],
      },
    },
  };
  Map<String, dynamic> suggestions(String name) => {
    'code': 0,
    'data': {
      'topic_items': [
        {'id': 12, 'name': name},
      ],
      'page_info': {'has_more': false},
    },
  };
  Map<String, dynamic> mentions(String name) => {
    'code': 0,
    'data': {
      'groups': [
        {
          'group_name': name,
          'items': [
            {'uid': '1', 'name': name},
          ],
        },
      ],
    },
  };

  setUpAll(() {
    GStorage.setting = MemoryBox({SettingBoxKey.filterBlockedAuthors: false});
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() async {
    original = account(1);
    recommend = account(2);
    Accounts.accountMode[AccountType.main.index] = original;
    Accounts.accountMode[AccountType.recommend.index] = recommend;
    await GStorage.localCache.putAll({
      LocalCacheKey.mixinKey: 'synthetic',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    Get.parameters = {'id': '12', 'name': '话题'};
    Get.put<DynamicsController>(_Dynamics());
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
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    Get.parameters = {'id': '12', 'name': '话题'};
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  testWidgets('空间删除防重复，待确认及列表或账号变化不误删', (tester) async {
    await mount(tester);
    final controller = own(MemberDynamicsController(1));
    final list = [item('1')];
    controller.loadingState.value = Success(list);
    var remove = controller.onRemove('1');
    await controller.onRemove('1');
    await until(tester, () => requests.length == 1);
    expect(requests.single.options.path, Api.removeDynamic);
    expect(requests.single.options.extra['account'], same(original));
    requests.single.reply.complete({'code': '0'});
    await settle(tester);
    await remove;
    expect(list, hasLength(1));
    expect(find.text('操作结果待确认，请先核对后再操作'), findsOneWidget);

    remove = controller.onRemove('1');
    await until(tester, () => requests.length == 2);
    final refreshed = [item('1')];
    controller.loadingState.value = Success(refreshed);
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await remove;
    expect(refreshed, hasLength(1));
    expect(list, hasLength(1));
    expect(find.text('删除成功'), findsNothing);

    remove = controller.onRemove('1');
    await until(tester, () => requests.length == 3);
    Accounts.accountMode[AccountType.main.index] = account(3);
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await remove;
    expect(refreshed, hasLength(1));
    await finish(tester);
  });

  testWidgets('空间置顶互斥，保留普通标签并只取消目标置顶', (tester) async {
    await mount(tester);
    final controller = own(MemberDynamicsController(1));
    final ordinary = item('1')..modules.moduleTag = ModuleTag(text: '普通标签');
    final oldTop = item('2')..modules.moduleTag = ModuleTag(text: '置顶');
    final target = item('3');
    final list = [ordinary, oldTop, target];
    controller.loadingState.value = Success(list);
    var setTop = controller.onSetTop(false, '3');
    await controller.onSetTop(false, '3');
    await controller.onRemove('1');
    await until(tester, () => requests.length == 1);
    expect(requests.single.options.extra['account'], same(original));
    requests.single.reply.complete({'code': 0});
    await settle(tester);
    await setTop;
    expect(list, [target, ordinary, oldTop]);
    expect(ordinary.modules.moduleTag?.text, '普通标签');
    expect(oldTop.modules.moduleTag, isNull);
    expect(target.modules.moduleTag?.text, '置顶');

    list
      ..remove(target)
      ..add(target);
    setTop = controller.onSetTop(true, '3');
    await until(tester, () => requests.length == 2);
    requests.last.reply.complete({'code': -667777, 'message': '拒绝置顶'});
    await settle(tester);
    await setTop;
    expect(target.modules.moduleTag?.text, '置顶');
    expect(find.text('拒绝置顶'), findsOneWidget);
    setTop = controller.onSetTop(true, '3');
    await until(tester, () => requests.length == 3);
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await setTop;
    expect(target.modules.moduleTag, isNull);
    expect(ordinary.modules.moduleTag?.text, '普通标签');
    expect(list, [ordinary, oldTop, target]);
    await finish(tester);
  });

  test('空间动态凭据替换后重载，旧查询不覆盖新列表并释放订阅', () async {
    final controller = own(_Member())..onInit();
    await interceptor.waitForRequests(1);
    final replacement = account(1, 'replacement');
    Accounts.replaceCredentials(replacement);
    await interceptor.waitForRequests(2);
    expect(requests.last.options.extra['account'], same(replacement));
    requests.last.reply.complete(dynamics('2'));
    await controller.queries.last;
    requests.first.reply.complete(dynamics('1'));
    await controller.queries.first;
    expect(controller.loadingState.value.data!.single.idStr, '2');
    expect(controller.offset, '2');
    controller.onDelete();
    Accounts.replaceCredentials(account(1, 'closed'));
    expect(requests, hasLength(2));
  });

  testWidgets('动态页删除固定账号，目标作者变化或失败时保留列表', (tester) async {
    await mount(tester);
    final controller = own(
      DynamicsTabController(dynamicsType: DynamicsTabType.up),
    );
    final list = [item('1')];
    controller.loadingState.value = Success(list);
    var remove = controller.onRemove(0, '1');
    await controller.onRemove(0, '1');
    await until(tester, () => requests.length == 1);
    expect(requests.single.options.extra['account'], same(original));
    Get.find<DynamicsController>().hostMid = 2;
    requests.single.reply.complete({'code': 0});
    await settle(tester);
    await remove;
    expect(list, hasLength(1));
    expect(find.text('删除成功'), findsNothing);
    remove = controller.onRemove(0, '1');
    await until(tester, () => requests.length == 2);
    requests.last.reply.complete({'code': -667777, 'message': '无删除权限'});
    await settle(tester);
    await remove;
    expect(list, hasLength(1));
    expect(find.text('无删除权限'), findsOneWidget);
    remove = controller.onRemove(0, '1');
    await until(tester, () => requests.length == 3);
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await remove;
    expect(list, isEmpty);
    await finish(tester);
  });

  test('动态页同账号换凭据重载，展开只触及过滤后仍在列表的折叠 ID', () async {
    final controller = own(_Tab())..onInit();
    await interceptor.waitForRequests(1);
    final replacement = account(1, 'replacement');
    Accounts.replaceCredentials(replacement);
    await interceptor.waitForRequests(2);
    expect(requests.last.options.extra['account'], same(replacement));
    requests.last.reply.complete(dynamics('2'));
    await controller.queries.last;
    requests.first.reply.complete(dynamics('1'));
    await controller.queries.first;
    expect(controller.loadingState.value.data!.single.idStr, '2');
    final fold = item('fold')
      ..modules.moduleFold = ModuleFold.fromJson({
        'ids': ['filtered', '2'],
      });
    final folded = item('2')..visible = false;
    final unrelated = item('3')..visible = false;
    controller.loadingState.value = Success([fold, unrelated, folded]);
    controller.onUnfold(fold, 0);
    expect(fold.modules.moduleFold, isNull);
    expect(folded.visible, isTrue);
    expect(unrelated.visible, isFalse);
    controller.onBlock(-1);
    controller.onDelete();
    Accounts.replaceCredentials(account(1, 'closed'));
    expect(requests, hasLength(2));
  });

  test('话题详情允许空结果、拒绝不完整数据，并隔离乱序和关闭结果', () async {
    final controller = own(DynTopicController());
    var query = controller.queryTop();
    await interceptor.waitForRequests(1);
    expect(requests.single.options.extra['account'], same(original));
    requests.single.reply.complete({'code': 0});
    await query;
    expect(controller.topState.value, isA<Success<TopDetails?>>());
    expect(controller.topState.value.data, isNull);
    query = controller.queryTop();
    await interceptor.waitForRequests(2);
    requests.last.reply.complete({
      'code': 0,
      'data': {'top_details': <String, dynamic>{}},
    });
    await query;
    expect(controller.topState.value, isA<Error>());
    expect(controller.topState.value.toString(), '话题信息不完整，请重试');

    final previous = controller.queryTop();
    query = controller.queryTop();
    await interceptor.waitForRequests(4);
    requests.last.reply.complete(top('新话题'));
    await query;
    requests[2].reply.complete(top('旧话题'));
    await previous;
    expect(controller.topicName, '新话题');
    query = controller.queryTop();
    await interceptor.waitForRequests(5);
    controller.onDelete();
    requests.last.reply.complete(top('已关闭'));
    await query;
    expect(controller.topicName, '新话题');
  });

  test('话题头部绑定主账号，内容绑定推荐账号，两种凭据变更均重载', () async {
    final controller = own(_Topic())..onInit();
    await interceptor.waitForRequests(2);
    final mainReplacement = account(1, 'main-replacement');
    Accounts.replaceCredentials(mainReplacement);
    await interceptor.waitForRequests(4);
    final recommendReplacement = account(2, 'recommend-replacement');
    Accounts.replaceCredentials(recommendReplacement);
    await interceptor.waitForRequests(6);
    final latestTop = requests.lastWhere((r) => r.options.path == Api.topicTop);
    final latestFeed = requests.lastWhere(
      (r) => r.options.path == Api.topicFeed,
    );
    expect(latestTop.options.extra['account'], same(mainReplacement));
    expect(latestFeed.options.extra['account'], same(recommendReplacement));
    latestTop.reply.complete(top('最新账号'));
    latestFeed.reply.complete(feed('3'));
    await Future.wait([controller.tops.last, controller.queries.last]);
    for (final request in requests.where((r) => !r.reply.isCompleted)) {
      request.reply.complete(
        request.options.path == Api.topicTop ? top('旧账号') : feed('1'),
      );
    }
    await Future.wait([...controller.tops, ...controller.queries]);
    expect(controller.topicName, '最新账号');
    expect(
      controller.loadingState.value.data!.single.dynamicCardItem!.idStr,
      '3',
    );
    controller.onDelete();
    Accounts.replaceCredentials(account(1, 'closed'));
    Accounts.replaceCredentials(account(2, 'closed'));
    expect(requests, hasLength(6));
  });

  testWidgets('话题收藏点赞防重复，待确认及旧详情不改当前计数', (tester) async {
    await mount(tester);
    final controller = own(DynTopicController());
    final details = topic();
    controller.topState.value = Success(TopDetails(topicItem: details));
    var save = controller.onFav();
    await controller.onFav();
    await until(tester, () => requests.length == 1);
    expect(requests.single.options.path, Api.addFavTopic);
    expect(requests.single.options.extra['account'], same(original));
    requests.single.reply.complete({'code': '0'});
    await settle(tester);
    await save;
    expect(details.fav, 2);
    expect(controller.isFav.value, isFalse);
    expect(find.text('操作结果待确认，请先核对后再操作'), findsOneWidget);
    save = controller.onFav();
    await until(tester, () => requests.length == 2);
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await save;
    expect(details.fav, 3);
    expect(details.isFav, isTrue);
    expect(controller.isFav.value, isTrue);

    save = controller.onLike();
    await controller.onLike();
    await until(tester, () => requests.length == 3);
    final refreshed = topic('刷新后的话题');
    controller.topState.value = Success(TopDetails(topicItem: refreshed));
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await save;
    expect(details.like, 3);
    expect(refreshed.like, 3);
    expect(controller.isLike.value, isFalse);
    save = controller.onLike();
    await until(tester, () => requests.length == 4);
    Accounts.accountMode[AccountType.main.index] = account(3);
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await save;
    expect(refreshed.like, 3);
    await finish(tester);
  });

  testWidgets('话题折叠失败可见且可重试，展开替换占位项并保留后来分页项', (tester) async {
    await mount(tester);
    final controller = own(DynTopicController());
    final fold = TopicCardItem(foldCardItem: FoldCardItem(foldCount: 1));
    final first = TopicCardItem(dynamicCardItem: item('1'));
    final later = TopicCardItem(dynamicCardItem: item('3'));
    final list = [first, fold];
    controller.loadingState.value = Success(list);
    var unfold = controller.topicFold();
    await controller.topicFold();
    await until(tester, () => requests.length == 1);
    expect(requests.single.options.extra['account'], same(recommend));
    requests.single.reply.complete({'code': -667777, 'message': '展开失败'});
    await settle(tester);
    await unfold;
    expect(list, [first, fold]);
    expect(find.text('展开失败'), findsOneWidget);
    unfold = controller.topicFold();
    await until(tester, () => requests.length == 2);
    list.add(later);
    requests.last.reply.complete(feed('2'));
    await settle(tester);
    await unfold;
    expect(list.map((e) => e.dynamicCardItem?.idStr), ['1', '2', '3']);
    expect(list.last, same(later));
    await finish(tester);
  });

  test('话题折叠拒绝旧排序、旧列表和旧推荐账号的结果', () async {
    final controller = own(DynTopicController());
    final fold = TopicCardItem(foldCardItem: FoldCardItem(foldCount: 1));
    final list = [fold];
    controller.loadingState.value = Success(list);
    var unfold = controller.topicFold();
    await interceptor.waitForRequests(1);
    controller.sortBy = 1;
    requests.last.reply.complete(feed('2'));
    await unfold;
    expect(list, [fold]);
    unfold = controller.topicFold();
    await interceptor.waitForRequests(2);
    final refreshed = [TopicCardItem(foldCardItem: FoldCardItem(foldCount: 1))];
    controller.loadingState.value = Success(refreshed);
    requests.last.reply.complete(feed('2'));
    await unfold;
    expect(list, [fold]);
    expect(refreshed.single.foldCardItem, isNotNull);
    unfold = controller.topicFold();
    await interceptor.waitForRequests(3);
    Accounts.accountMode[AccountType.recommend.index] = account(3);
    requests.last.reply.complete(feed('2'));
    await unfold;
    expect(refreshed.single.foldCardItem, isNotNull);
  });

  test('话题选择和提及隔离刷新乱序，凭据替换清除旧选择并释放订阅', () async {
    final selection = own(_Selection())..onInit();
    final mention = own(_Mentions())..onInit();
    await interceptor.waitForRequests(2);
    final oldSelection = requests.singleWhere(
      (r) => r.options.path == Api.topicPubSearch,
    );
    final oldMention = requests.singleWhere(
      (r) => r.options.path == Api.dynMention,
    );
    selection.controller.text = '新关键字';
    mention.controller.text = '新关键字';
    final refreshSelection = selection.onRefresh();
    final refreshMention = mention.onRefresh();
    await interceptor.waitForRequests(4);
    final newSelection = requests.lastWhere(
      (r) => r.options.path == Api.topicPubSearch,
    );
    final newMention = requests.lastWhere(
      (r) => r.options.path == Api.dynMention,
    );
    expect(newSelection.options.queryParameters['keywords'], '新关键字');
    expect(newMention.options.queryParameters['keyword'], '新关键字');
    newSelection.reply.complete(suggestions('新话题'));
    newMention.reply.complete(mentions('新用户'));
    await Future.wait([refreshSelection, refreshMention]);
    oldSelection.reply.complete(suggestions('旧话题'));
    oldMention.reply.complete(mentions('旧用户'));
    await Future.wait([selection.queries.first, mention.queries.first]);
    expect(selection.loadingState.value.data!.single.name, '新话题');
    expect(mention.loadingState.value.data!.single.groupName, '新用户');
    mention
      ..onCheck(false, MentionItem(uid: 'missing'))
      ..onCheck(true, MentionItem(uid: '1'));
    expect(mention.showBtn.value, isTrue);
    final replacement = account(1, 'replacement');
    Accounts.replaceCredentials(replacement);
    expect(mention.showBtn.value, isFalse);
    expect(mention.mentionList, isEmpty);
    await interceptor.waitForRequests(6);
    for (final request in requests.skip(4)) {
      expect(request.options.extra['account'], same(replacement));
      request.reply.complete(
        request.options.path == Api.topicPubSearch
            ? suggestions('新账号话题')
            : mentions('新账号用户'),
      );
    }
    await Future.wait([selection.queries.last, mention.queries.last]);
    expect(selection.loadingState.value.data!.single.name, '新账号话题');
    expect(mention.loadingState.value.data!.single.groupName, '新账号用户');
    selection.onDelete();
    mention.onDelete();
    Accounts.replaceCredentials(account(1, 'closed'));
    expect(requests, hasLength(6));
  });
}
