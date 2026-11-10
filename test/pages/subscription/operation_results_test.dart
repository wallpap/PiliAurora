import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/subscription/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _FailDeleteBox extends MemoryBox<dynamic> {
  bool failDelete = false;
  @override
  Future<void> delete(dynamic key) async {
    if (failDelete) throw StateError('fixture cache delete failure');
    await super.delete(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  late SubController controller;
  final cache = _FailDeleteBox();
  LoginAccount login(String csrf) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': csrf}),
    null,
    null,
  )..activated = true;
  Map<String, dynamic> subscriptions(List<int> ids) => {
    'code': 0,
    'data': {
      'list': [
        for (final id in ids) {'id': id, 'type': 21, 'state': 1},
      ],
      'has_more': false,
    },
  };
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    Accounts.account = MemoryBox<LoginAccount>();
    GStorage.localCache = cache;
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() {
    requests.clear();
    cache.failDelete = false;
    cache.data.clear();
    Accounts.accountMode[AccountType.main.index] = login('old');
  });
  tearDown(() async {
    await Get.delete<SubController>(force: true);
    Get.reset();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: Text('订阅')),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    await tester.runAsync(() async {
      controller = Get.put(SubController());
      await interceptor.waitForRequests(1);
      requests.single.reply.complete(subscriptions([1, 2]));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
  }

  VoidCallback action(WidgetTester tester, String text) => tester
      .widget<TextButton>(find.widgetWithText(TextButton, text))
      .onPressed!;
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
    await Get.delete<SubController>(force: true);
    Get.reset();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  Future<void> openCancel(WidgetTester tester) async {
    controller.cancelSub(controller.loadingState.value.data!.first);
    await tester.pumpAndSettle();
  }

  Future<void> openCleanup(WidgetTester tester) async {
    await tester.runAsync(() async {
      controller.cleanInvalidSubscriptions();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      action(tester, '确认')();
      await interceptor.waitForRequests(2);
    });
  }

  testWidgets('取消订阅防重，拒绝和待确认保留弹窗，成功才移除原订阅', (tester) async {
    await mount(tester);
    await openCancel(tester);
    final submit = action(tester, '确定');
    await tester.runAsync(() async {
      submit();
      submit();
      await interceptor.waitForRequests(2);
    });
    expect((requests.last.options.data as Map)['csrf'], 'old');
    for (final body in [
      {'code': -403, 'message': '拒绝取消'},
      {'message': 'unknown'},
    ]) {
      await resolve(tester, requests.length - 1, body);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(controller.loadingState.value.data, hasLength(2));
      final expected = requests.length + 1;
      await tester.runAsync(() async {
        action(tester, '确定')();
        await interceptor.waitForRequests(expected);
      });
    }
    cache.failDelete = true;
    await resolve(tester, requests.length - 1, {'code': 0});
    await tester.pumpAndSettle();
    expect(controller.loadingState.value.data!.map((item) => item.id), [2]);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('取消订阅成功，本地记录清理失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('确认前换凭据不向新账号提交旧弹窗目标', (tester) async {
    await mount(tester);
    await openCancel(tester);
    await tester.runAsync(() async {
      Accounts.replaceCredentials(login('new'));
      await interceptor.waitForRequests(2);
    });
    await resolve(tester, 1, subscriptions([3, 4]));
    action(tester, '确定')();
    await tester.pumpAndSettle();
    expect(requests, hasLength(2));
    expect(controller.loadingState.value.data!.map((item) => item.id), [3, 4]);
    expect(find.text('账号或订阅已更新，请重新打开'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('已关闭取消弹窗的迟到成功不关闭新页面', (tester) async {
    await mount(tester);
    await openCancel(tester);
    await tester.runAsync(() async {
      action(tester, '确定')();
      await interceptor.waitForRequests(2);
    });
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    Get.to(() => const Scaffold(body: Text('新页面')));
    await tester.pumpAndSettle();
    await resolve(tester, 1, {'code': 0});
    await tester.pumpAndSettle();
    expect(find.text('新页面'), findsOneWidget);
    expect(find.text('取消订阅成功'), findsNothing);
    expect(controller.loadingState.value.data!.map((item) => item.id), [2]);
    await finish(tester);
  });

  testWidgets('清理区分取消待确认，并释放锁后真正刷新订阅列表', (tester) async {
    await mount(tester);
    await openCleanup(tester);
    await resolve(tester, 1, subscriptions([1]));
    await tester.runAsync(() => interceptor.waitForRequests(3));
    expect(requests.last.options.path, Api.unfavSeason);
    await resolve(tester, 2, {'message': 'unknown'});
    await tester.runAsync(() => interceptor.waitForRequests(4));
    expect(requests.last.options.path, Api.userSubFolder);
    await resolve(tester, 3, subscriptions([2]));
    await tester.pumpAndSettle();
    expect(controller.isCleaning.value, isFalse);
    expect(controller.cleanupProgress.value, isEmpty);
    expect(find.textContaining('1 个取消结果待确认'), findsOneWidget);
    expect(controller.loadingState.value.data!.map((item) => item.id), [2]);
    for (final request in requests) {
      expect(request.options.extra['account'], same(Accounts.main));
    }
    await finish(tester);
  });

  testWidgets('清理远端成功不被本地隐藏记录删除失败覆盖', (tester) async {
    await mount(tester);
    cache.failDelete = true;
    await openCleanup(tester);
    await resolve(tester, 1, subscriptions([1]));
    await tester.runAsync(() => interceptor.waitForRequests(3));
    await resolve(tester, 2, {'code': 0});
    await tester.runAsync(() => interceptor.waitForRequests(4));
    await resolve(tester, 3, subscriptions([2]));
    await tester.pumpAndSettle();
    expect(find.textContaining('已取消 1 个订阅'), findsOneWidget);
    expect(find.textContaining('1 项本地记录清理失败'), findsOneWidget);
    expect(find.textContaining('1 个订阅清理失败'), findsNothing);
    expect(controller.isCleaning.value, isFalse);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('同 mid 换凭据后旧清理停止，旧快照不会取消新账号订阅', (tester) async {
    await mount(tester);
    await openCleanup(tester);
    await tester.runAsync(() async {
      Accounts.replaceCredentials(login('new'));
      await interceptor.waitForRequests(3);
    });
    await resolve(tester, 2, subscriptions([3]));
    await resolve(tester, 1, subscriptions([1]));
    await tester.pumpAndSettle();
    expect(requests, hasLength(3));
    expect(
      requests.every((request) => request.options.method == 'GET'),
      isTrue,
    );
    expect(controller.loadingState.value.data!.map((item) => item.id), [3]);
    expect(controller.isCleaning.value, isFalse);
    await finish(tester);
  });
}
