import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/fav/fav_detail/media.dart';
import 'package:pili_aurora/models/remote/fav/fav_folder/list.dart';
import 'package:pili_aurora/pages/fav/video/controller.dart';
import 'package:pili_aurora/pages/fav_detail/controller.dart';
import 'package:pili_aurora/pages/fav_folder_sort/view.dart';
import 'package:pili_aurora/pages/fav_sort/view.dart';
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
  final account = LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'fixture'}),
    null,
    null,
  );
  late GlobalKey<NavigatorState> navigator;
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() {
    Accounts.accountMode[AccountType.main.index] = account;
    navigator = GlobalKey<NavigatorState>();
    requests.clear();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  FavDetailController controller() {
    final controller = FavDetailController()
      ..mediaId = 7
      ..isEnd = true;
    controller.folderInfo.value
      ..title = 'sample'
      ..mediaCount = 2;
    controller.loadingState.value = Success([
      for (var id = 1; id <= 2; id++)
        FavDetailItemModel(id: id, type: 2, title: 'item $id'),
    ]);
    addTearDown(controller.onClose);
    return controller;
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: Text('root')),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    await tester.pump();
  }

  Future<void> dispatched(WidgetTester tester, int count) async {
    final deadline = tester.binding.clock.now().add(const Duration(seconds: 3));
    while (requests.length < count &&
        tester.binding.clock.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(requests, hasLength(count));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
  }

  Future<void> sort(WidgetTester tester, FavDetailController controller) async {
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => FavSortPage(favDetailController: controller),
      ),
    );
    await settle(tester);
    tester
        .widget<ReorderableListView>(find.byType(ReorderableListView))
        .onReorderItem!(0, 1);
    await tester.pump();
  }

  Future<void> chooseTarget(WidgetTester tester) async {
    await dispatched(tester, 1);
    requests[0].reply.complete({
      'code': 0,
      'data': {
        'list': [
          {'id': 8, 'title': '目标', 'attr': 0},
        ],
      },
    });
    await settle(tester);
    await tester.tap(find.text('目标'));
    await tester.pump();
    await tester.tap(find.text('确认'));
    await dispatched(tester, 2);
  }

  testWidgets('排序待确认保留草稿，确认成功后提交副本并关闭所属页面', (tester) async {
    await mount(tester);
    final ctr = controller();
    final source = ctr.loadingState.value.data!;
    await sort(tester, ctr);
    await tester.tap(find.text('完成'));
    await dispatched(tester, 1);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '完成'))
          .onPressed,
      isNull,
    );
    requests[0].reply.complete({'code': '0'});
    await settle(tester);
    expect(source.map((item) => item.id), [1, 2]);
    expect(find.byType(FavSortPage), findsOneWidget);
    expect(find.text('操作结果待确认，请先核对后再操作'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await dispatched(tester, 2);
    expect(requests[1].options.extra['account'], same(account));
    requests[1].reply.complete({'code': 0});
    await settle(tester);
    expect(ctr.loadingState.value.data!.map((item) => item.id), [2, 1]);
    expect(ctr.loadingState.value.data, isNot(same(source)));
    expect(find.byType(FavSortPage), findsNothing);
    await finish(tester);
  });

  testWidgets('退出排序后的迟到成功不改列表、不退出新页面', (tester) async {
    await mount(tester);
    final ctr = controller();
    await sort(tester, ctr);
    await tester.tap(find.text('完成'));
    await dispatched(tester, 1);
    navigator.currentState!.pop();
    await settle(tester);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('新页面')),
      ),
    );
    await settle(tester);
    requests[0].reply.complete({'code': 0});
    await settle(tester);
    expect(ctr.loadingState.value.data!.map((item) => item.id), [1, 2]);
    expect(find.text('新页面'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('批量移除拒绝重叠请求，待确认保留选择和计数，切号拒绝迟到结果', (tester) async {
    await mount(tester);
    final ctr = controller();
    final source = ctr.loadingState.value.data!;
    source.first.checked = true;
    final remove = ctr.removeFavorites(source.toSet());
    await dispatched(tester, 1);
    await ctr.onCancelFav(0, 1, 2);
    expect(requests, hasLength(1));
    requests[0].reply.complete({'code': '0'});
    await settle(tester);
    await remove;
    expect(source, hasLength(2));
    expect(source.first.checked, isTrue);
    expect(ctr.folderInfo.value.mediaCount, 2);

    final retry = ctr.removeFavorites(source.toSet());
    await dispatched(tester, 2);
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    requests[1].reply.complete({'code': 0});
    await settle(tester);
    await retry;
    expect(source, hasLength(2));
    await finish(tester);
  });

  testWidgets('迁移待确认保留选择，可重试且只按本次选择扣减数量', (tester) async {
    await mount(tester);
    final ctr = controller();
    ctr.enableMultiSelect.value = true;
    ctr.rxCount.value = 1;
    final source = ctr.loadingState.value.data!;
    source.first.checked = true;
    final move = RequestUtils.onCopyOrMove<FavDetailItemModel>(
      context: tester.element(find.byType(Scaffold)),
      isCopy: false,
      ctr: ctr,
      mediaId: 7,
      mid: account.mid,
    );
    await chooseTarget(tester);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '提交中'))
          .onPressed,
      isNull,
    );
    requests[1].reply.complete({'code': '0'});
    await settle(tester);
    expect(source.first.checked, isTrue);
    expect(source, hasLength(2));
    expect(ctr.folderInfo.value.mediaCount, 2);
    await tester.tap(find.text('确认'));
    await dispatched(tester, 3);
    expect(requests[2].options.extra['account'], same(account));
    requests[2].reply.complete({'code': 0});
    await settle(tester);
    await move;
    expect(source.map((item) => item.id), [2]);
    expect(ctr.folderInfo.value.mediaCount, 1);
    expect(ctr.checkedCount, 0);
    await finish(tester);
  });

  testWidgets('关闭迁移面板后的迟到成功保留列表与新页面', (tester) async {
    await mount(tester);
    final ctr = controller();
    final source = ctr.loadingState.value.data!;
    source.first.checked = true;
    final move = RequestUtils.onCopyOrMove<FavDetailItemModel>(
      context: tester.element(find.byType(Scaffold)),
      isCopy: false,
      ctr: ctr,
      mediaId: 7,
      mid: account.mid,
    );
    await chooseTarget(tester);
    navigator.currentState!.pop();
    await settle(tester);
    await move;
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('新页面')),
      ),
    );
    await settle(tester);
    requests[1].reply.complete({'code': 0});
    await settle(tester);
    expect(source, hasLength(2));
    expect(source.first.checked, isTrue);
    expect(find.text('新页面'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('收藏详情缺少文件夹信息时呈现错误并允许重试', (tester) async {
    await mount(tester);
    final ctr = controller();
    final query = ctr.onRefresh();
    await dispatched(tester, 1);
    requests[0].reply.complete({'code': 0, 'data': <String, dynamic>{}});
    await settle(tester);
    await query;
    expect(ctr.loadingState.value, isA<Error>());
    expect(ctr.loadingState.value.toString(), '收藏夹信息不完整，请重试');
    expect(ctr.isLoading, isFalse);
    await finish(tester);
  });

  testWidgets('收藏夹排序保护默认文件夹，失败保留草稿并可重试', (tester) async {
    await mount(tester);
    final ctr = FavController()..isEnd = true;
    addTearDown(ctr.onClose);
    final source = [
      for (var id = 1; id <= 3; id++)
        FavFolderInfo(id: id, title: 'folder $id'),
    ];
    ctr.loadingState.value = Success(source);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => FavFolderSortPage(favController: ctr),
      ),
    );
    await settle(tester);
    final reorder = tester
        .widget<ReorderableListView>(find.byType(ReorderableListView))
        .onReorderItem!;
    reorder(0, 1);
    await tester.pump();
    reorder(1, 2);
    await tester.pump();
    await tester.tap(find.text('完成'));
    await dispatched(tester, 1);
    expect((requests[0].options.data as Map)['sort'], '1,3,2');
    expect(requests[0].options.extra['account'], same(account));
    requests[0].reply.complete({'code': -403, 'message': '排序被拒绝'});
    await settle(tester);
    expect(source.map((item) => item.id), [1, 2, 3]);
    expect(find.byType(FavFolderSortPage), findsOneWidget);
    await tester.tap(find.text('完成'));
    await dispatched(tester, 2);
    requests[1].reply.complete({'code': 0});
    await settle(tester);
    expect(ctr.loadingState.value.data!.map((item) => item.id), [1, 3, 2]);
    expect(find.byType(FavFolderSortPage), findsNothing);
    await finish(tester);
  });

  testWidgets('删除收藏夹防重入，待确认和切号后都不回调旧页面', (tester) async {
    await mount(tester);
    final ctr = controller();
    var completed = 0;
    final remove = ctr.deleteFolder(() => completed++);
    await dispatched(tester, 1);
    await ctr.deleteFolder(() => completed++);
    expect(requests, hasLength(1));
    requests[0].reply.complete({'code': '0'});
    await settle(tester);
    await remove;
    expect(completed, 0);
    final retry = ctr.deleteFolder(() => completed++);
    await dispatched(tester, 2);
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    requests[1].reply.complete({'code': 0});
    await settle(tester);
    await retry;
    expect(completed, 0);
    await finish(tester);
  });
}
