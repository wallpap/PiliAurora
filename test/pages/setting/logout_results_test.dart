import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/setting/models/model.dart';
import 'package:pili_aurora/pages/setting/models/privacy_settings.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _AccountBox extends MemoryBox<LoginAccount> {
  @override
  bool get isEmpty => data.isEmpty;
}

class _Account extends LoginAccount {
  _Account(int id)
    : super(
        BiliCookieJar.fromJson({'DedeUserID': '$id', 'bili_jct': 'csrf-$id'}),
        null,
        null,
      );
  var failDelete = false;
  var failAfterDelete = false;
  var deletes = 0;
  @override
  Future<void> delete() async {
    deletes++;
    if (failDelete) throw StateError('fixture delete failure');
    await Accounts.account.delete('$mid');
    if (failAfterDelete) throw StateError('fixture cleanup failure');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  var refreshes = 0;
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Accounts.account = _AccountBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() {
    requests.clear();
    refreshes = 0;
    (Accounts.account as MemoryBox).data.clear();
    for (final role in AccountType.values) {
      Accounts.accountMode[role.index] = AnonymousAccount();
    }
  });
  tearDown(Get.reset);
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> mount(WidgetTester tester, List<_Account> accounts) async {
    for (final account in accounts) {
      await Accounts.account.put('${account.mid}', account);
    }
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: Text('设置')),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    final item = privacySettings.whereType<NormalModel>().singleWhere(
      (i) => i.title == '退出登录',
    );
    item.onTap!(tester.element(find.text('设置')), () => refreshes++);
    await tester.pumpAndSettle();
    for (final account in accounts) {
      await tester.tap(find.text('${account.mid}'));
    }
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
  }

  VoidCallback action(WidgetTester tester, String text) => tester
      .widget<TextButton>(find.widgetWithText(TextButton, text))
      .onPressed!;
  Future<void> submit(WidgetTester tester, int count) =>
      tester.runAsync(() async {
        action(tester, '确认')();
        await interceptor.waitForRequests(count);
      });
  Future<void> resolve(WidgetTester tester, int index, Object body) =>
      tester.runAsync(() async {
        requests[index].reply.complete(body);
        await Future<void>.delayed(Duration.zero);
      });
  Future<void> finish(WidgetTester tester) async {
    final dismissal = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismissal;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  testWidgets('多账号退出防重，明确失败与待确认保留选择，只清理远端成功账号', (tester) async {
    final accounts = [_Account(1), _Account(2), _Account(3)];
    await mount(tester, accounts);
    final send = action(tester, '确认');
    await tester.runAsync(() async {
      send();
      send();
      await interceptor.waitForRequests(3);
    });
    await tester.pump();
    expect(find.text('处理中'), findsOneWidget);
    await resolve(tester, 0, {'code': 0});
    await resolve(tester, 1, {'code': -403, 'message': '拒绝退出'});
    await resolve(tester, 2, {'message': 'missing-code'});
    await tester.pumpAndSettle();
    expect(accounts.map((a) => a.deletes), [1, 0, 0]);
    expect(Accounts.account.values.map((a) => a.mid), [2, 3]);
    expect(find.textContaining('拒绝退出'), findsOneWidget);
    expect(find.textContaining('操作结果待确认'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(refreshes, 1);
    for (var i = 0; i < accounts.length; i++) {
      expect(requests[i].options.extra['account'], same(accounts[i]));
    }
    await finish(tester);
  });

  testWidgets('远端成功后的本地失败保留结果，再次确认仅重试清理', (tester) async {
    final account = _Account(1)..failDelete = true;
    await mount(tester, [account]);
    await submit(tester, 1);
    await resolve(tester, 0, {'code': 0});
    await tester.pumpAndSettle();
    expect(account.deletes, 1);
    expect(find.textContaining('远端已退出，本地清理失败'), findsOneWidget);
    account.failDelete = false;
    await tester.runAsync(() async {
      action(tester, '确认')();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));
    expect(account.deletes, 2);
    expect(Accounts.account.isEmpty, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('所选账号已退出登录'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('同 mid 更新凭据后，旧退出回执不删除新登录或重复撤销', (tester) async {
    final account = _Account(1);
    await mount(tester, [account]);
    await submit(tester, 1);
    final replacement = _Account(1);
    await Accounts.account.put('1', replacement);
    await resolve(tester, 0, {'code': 0});
    await tester.pumpAndSettle();
    expect(account.deletes, 0);
    expect(replacement.deletes, 0);
    expect(Accounts.account.get('1'), same(replacement));
    expect(find.textContaining('登录信息已更新'), findsOneWidget);
    await tester.runAsync(() async {
      action(tester, '确认')();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));
    expect(replacement.deletes, 0);
    await finish(tester);
  });

  testWidgets('账号已移除后的清理失败不覆盖远端成功或保留待重发账号', (tester) async {
    final account = _Account(1)..failAfterDelete = true;
    await mount(tester, [account]);
    await submit(tester, 1);
    await resolve(tester, 0, {'code': 0});
    await tester.pumpAndSettle();
    expect(account.deletes, 1);
    expect(Accounts.account.isEmpty, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('账号已登出，部分本地清理失败，请重启后核对'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('关闭后的远端成功继续清理授权账号，不关闭后来页面', (tester) async {
    final account = _Account(1);
    await mount(tester, [account]);
    await submit(tester, 1);
    await tester.tap(find.text('点错了'));
    await tester.pumpAndSettle();
    Get.to(() => const Scaffold(body: Text('新页面')));
    await tester.pumpAndSettle();
    await resolve(tester, 0, {'code': 0});
    await tester.pumpAndSettle();
    expect(account.deletes, 1);
    expect(Accounts.account.isEmpty, isTrue);
    expect(find.text('新页面'), findsOneWidget);
    expect(find.text('所选账号已退出登录'), findsNothing);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('仅登出失败仍保留账号，再次操作不调用远端撤销', (tester) async {
    final account = _Account(1)..failDelete = true;
    await mount(tester, [account]);
    await tester.runAsync(() async {
      action(tester, '仅登出')();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('本地清理失败'), findsOneWidget);
    account.failDelete = false;
    await tester.runAsync(() async {
      action(tester, '仅登出')();
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(account.deletes, 2);
    expect(find.byType(AlertDialog), findsNothing);
    await finish(tester);
  });
}
