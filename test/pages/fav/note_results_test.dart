import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/fav/fav_note/list.dart';
import 'package:pili_aurora/pages/fav/note/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  late FavNoteController controller;
  LoginAccount login(String csrf) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': csrf}),
    null,
    null,
  )..activated = true;
  Map<String, dynamic> notes(List<int> ids) => {
    'code': 0,
    'data': {
      'list': [
        for (final id in ids)
          {'note_id': id, 'cvid': id + 100, 'title': '笔记$id'},
      ],
    },
  };
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Accounts.account = MemoryBox<LoginAccount>();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() {
    requests.clear();
    Accounts.accountMode[AccountType.main.index] = login('old');
  });
  tearDown(() {
    Get
      ..delete<FavNoteController>(force: true)
      ..reset();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> mount(WidgetTester tester, {bool publish = false}) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: Text('笔记')),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    await tester.runAsync(() async {
      controller = Get.put(FavNoteController(publish));
      await interceptor.waitForRequests(1);
      requests.single.reply.complete(notes([1, 2]));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
  }

  Future<void> resolve(WidgetTester tester, int index, Object body) =>
      tester.runAsync(() async {
        requests[index].reply.complete(body);
        await Future<void>.delayed(Duration.zero);
      });
  Future<void> finish(WidgetTester tester) async {
    final dismiss = SmartDialog.dismiss(status: .allToast);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await dismiss;
    Get
      ..delete<FavNoteController>(force: true)
      ..reset();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  for (final scenario in [
    ('拒绝', <String, dynamic>{'code': -403, 'message': '拒绝删除'}),
    ('待确认', <String, dynamic>{'message': 'unknown'}),
    ('成功', <String, dynamic>{'code': 0}),
  ]) {
    testWidgets('笔记删除互斥，${scenario.$1}按确认结果保留选择或删除原项', (tester) async {
      await mount(tester);
      final list = controller.loadingState.value.data!;
      controller.enableMultiSelect.value = true;
      controller.onSelect(list.first);
      late Future<void> pending;
      await tester.runAsync(() async {
        pending = controller.onRemove();
        await controller.onRemove();
        await interceptor.waitForRequests(2);
      });
      controller.onSelect(list.last);
      expect(list.last.checked, isFalse);
      expect(controller.isRemoving.value, isTrue);
      expect((requests.last.options.data as Map)['note_ids'], '1');
      expect((requests.last.options.data as Map)['csrf'], 'old');
      await resolve(tester, 1, scenario.$2);
      await tester.runAsync(() async => await pending);
      expect(controller.isRemoving.value, isFalse);
      if (scenario.$1 == '成功') {
        expect(controller.loadingState.value.data!.map((item) => item.noteId), [
          2,
        ]);
        expect(controller.checkedCount, 0);
      } else {
        expect(list.first.checked, isTrue);
        expect(controller.checkedCount, 1);
        expect(controller.loadingState.value.data, hasLength(2));
      }
      await finish(tester);
    });
  }

  testWidgets('刷新为同数量的新笔记后，旧删除成功不清空新列表', (tester) async {
    await mount(tester);
    controller.handleSelect(checked: true);
    late Future<void> removal;
    late Future<void> refresh;
    await tester.runAsync(() async {
      removal = controller.onRemove();
      await interceptor.waitForRequests(2);
      refresh = controller.onRefresh();
      await interceptor.waitForRequests(3);
    });
    await resolve(tester, 2, notes([3, 4]));
    await tester.runAsync(() async => await refresh);
    await resolve(tester, 1, {'code': 0});
    await tester.runAsync(() async => await removal);
    expect(controller.loadingState.value.data!.map((item) => item.noteId), [
      3,
      4,
    ]);
    await finish(tester);
  });

  testWidgets('同账号换凭据使旧笔记删除失效，新查询绑定新账号', (tester) async {
    await mount(tester, publish: true);
    controller.onSelect(controller.loadingState.value.data!.first);
    late Future<void> removal;
    await tester.runAsync(() async {
      removal = controller.onRemove();
      await interceptor.waitForRequests(2);
      Accounts.replaceCredentials(login('new'));
      await interceptor.waitForRequests(3);
    });
    expect((requests[1].options.data as Map)['cvids'], '101');
    expect(requests[2].options.extra['account'], same(Accounts.main));
    expect(requests[2].options.queryParameters['csrf'], 'new');
    await resolve(tester, 2, notes([5, 6]));
    await resolve(tester, 1, {'code': 0});
    await tester.runAsync(() async => await removal);
    expect(controller.loadingState.value.data!.map((item) => item.noteId), [
      5,
      6,
    ]);
    expect(controller.checkedCount, 0);
    await finish(tester);
  });

  testWidgets('删除成功等待补页，后续查询失败不改写已确认成功', (tester) async {
    await mount(tester);
    controller.handleSelect(checked: true);
    late Future<void> removal;
    await tester.runAsync(() async {
      removal = controller.onRemove();
      await interceptor.waitForRequests(2);
    });
    await resolve(tester, 1, {'code': 0});
    await tester.runAsync(() => interceptor.waitForRequests(3));
    expect(controller.isRemoving.value, isTrue);
    await resolve(tester, 2, {'code': -403, 'message': '刷新失败'});
    await tester.runAsync(() async => await removal);
    await tester.pumpAndSettle();
    expect(find.text('删除成功'), findsOneWidget);
    expect(controller.loadingState.value, isA<Error>());
    expect(controller.isRemoving.value, isFalse);
    await finish(tester);
  });

  testWidgets('缺少有效 ID 不请求，公共删除助手不按相同数量清空其他对象', (tester) async {
    await mount(tester);
    controller.loadingState.value = Success([FavNoteItemModel()]);
    controller.handleSelect(checked: true);
    await controller.onRemove();
    expect(requests, hasLength(1));
    final current = [FavNoteItemModel(noteId: 3), FavNoteItemModel(noteId: 4)];
    controller.loadingState.value = Success(current);
    controller.handleSelect(checked: true);
    await controller.afterDelete({
      FavNoteItemModel(noteId: 1),
      FavNoteItemModel(noteId: 2),
    });
    expect(current.map((item) => item.noteId), [3, 4]);
    expect(controller.checkedCount, 2);
    expect(requests, hasLength(1));
    await finish(tester);
  });
}
