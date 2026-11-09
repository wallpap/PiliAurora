import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/later_view_type.dart';
import 'package:pili_aurora/models/remote/history/history.dart';
import 'package:pili_aurora/models/remote/history/list.dart';
import 'package:pili_aurora/models/remote/later/list.dart';
import 'package:pili_aurora/pages/history/base_controller.dart';
import 'package:pili_aurora/pages/history/controller.dart';
import 'package:pili_aurora/pages/history_search/controller.dart';
import 'package:pili_aurora/pages/later/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

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
  final main = account(1);
  final replacement = account(2);
  HistoryItemModel historyItem(int id) => HistoryItemModel(
    kid: id,
    history: History(business: 'archive'),
  );

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
    Accounts.accountMode[AccountType.main.index] = main;
    Accounts.accountMode[AccountType.heartbeat.index] = main;
    requests.clear();
  });
  tearDown(Get.reset);
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(),
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

  testWidgets('稍后再看移除与清空互斥，待确认保留列表和数量，后续可重新操作', (tester) async {
    await mount(tester);
    final controller = LaterController(LaterViewType.all);
    addTearDown(controller.onClose);
    final item = LaterItemModel(aid: 42);
    controller.loadingState.value = Success([item, LaterItemModel(aid: 43)]);
    controller.baseCtr.counts[LaterViewType.all.index] = 2;
    final remove = controller.removeLaterItems({item});
    await dispatched(tester, 1);
    await controller.removeLaterItems({item});
    await controller.clearLater();
    expect(requests, hasLength(1));
    requests[0].reply.complete({'code': '0'});
    await settle(tester);
    await remove;
    expect(controller.loadingState.value.data, hasLength(2));
    expect(controller.baseCtr.counts[LaterViewType.all.index], 2);
    expect(find.text('操作结果待确认，请先核对后再操作'), findsOneWidget);

    final retry = controller.removeLaterItems({item});
    await dispatched(tester, 2);
    requests[1].reply.complete({'code': 0});
    await settle(tester);
    await retry;
    expect(controller.loadingState.value.data!.map((item) => item.aid), [43]);
    expect(controller.baseCtr.counts[LaterViewType.all.index], 1);
    await finish(tester);
  });

  testWidgets('稍后再看刷新和切号后不接收迟到删除结果', (tester) async {
    await mount(tester);
    final controller = LaterController(LaterViewType.all);
    addTearDown(controller.onClose);
    final old = LaterItemModel(aid: 42);
    controller.loadingState.value = Success([old]);
    final remove = controller.removeLaterItems({old});
    await dispatched(tester, 1);
    final current = [LaterItemModel(aid: 42)];
    controller.loadingState.value = Success(current);
    requests[0].reply.complete({'code': 0});
    await settle(tester);
    await remove;
    expect(controller.loadingState.value.data, same(current));
    expect(current, hasLength(1));

    final second = controller.removeLaterItems(current.toSet());
    await dispatched(tester, 2);
    Accounts.accountMode[AccountType.main.index] = replacement;
    requests[1].reply.complete({'code': 0});
    await settle(tester);
    await second;
    expect(current, hasLength(1));
    await controller.clearLater();
    expect(requests, hasLength(2));
    await finish(tester);
  });

  testWidgets('历史暂停以确认写入为准，旧查询不会覆盖，切号清空不会调用旧页面', (tester) async {
    await mount(tester);
    final controller = HistoryBaseController();
    final query = controller.refreshHistoryStatus();
    await dispatched(tester, 1);
    final pause = controller.setHistoryPaused(true);
    await dispatched(tester, 2);
    await controller.setHistoryPaused(false);
    expect(requests, hasLength(2));
    requests[1].reply.complete({'code': 0});
    await settle(tester);
    await pause;
    requests[0].reply.complete({'code': 0, 'data': false});
    await settle(tester);
    await query;
    expect(controller.pauseStatus.value, isTrue);
    expect(GStorage.localCache.get(LocalCacheKey.historyPause), isTrue);

    var cleared = false;
    final clear = controller.clearHistory(() => cleared = true);
    await dispatched(tester, 3);
    Accounts.accountMode[AccountType.heartbeat.index] = replacement;
    requests[2].reply.complete({'code': 0});
    await settle(tester);
    await clear;
    expect(cleared, isFalse);
    await finish(tester);
  });

  testWidgets('历史删除互斥且绑定列表快照，待确认保留当前记录', (tester) async {
    await mount(tester);
    final controller = HistoryController('all');
    addTearDown(controller.onClose);
    final old = historyItem(42);
    controller.loadingState.value = Success([old]);
    final remove = controller.delHistory(old);
    await dispatched(tester, 1);
    await controller.delHistory(old);
    expect(requests, hasLength(1));
    final current = [historyItem(42)];
    controller.loadingState.value = Success(current);
    requests[0].reply.complete({'code': 0});
    await settle(tester);
    await remove;
    expect(current, hasLength(1));

    final second = controller.delHistory(current.single);
    await dispatched(tester, 2);
    requests[1].reply.complete({'code': '0'});
    await settle(tester);
    await second;
    expect(current, hasLength(1));
    expect(find.text('操作结果待确认，请先核对后再操作'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('历史搜索切号后拒绝迟到删除和后续写入', (tester) async {
    await mount(tester);
    final controller = HistorySearchController();
    addTearDown(controller.onClose);
    final items = [historyItem(42)];
    controller.loadingState.value = Success(items);
    final remove = controller.onDelHistory(0, 42, 'archive');
    await dispatched(tester, 1);
    Accounts.accountMode[AccountType.heartbeat.index] = replacement;
    requests[0].reply.complete({'code': 0});
    await settle(tester);
    await remove;
    expect(items, hasLength(1));
    await controller.onDelHistory(0, 42, 'archive');
    expect(requests, hasLength(1));
    await finish(tester);
  });
}
