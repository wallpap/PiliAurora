import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/member_profile/view.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  LoginAccount login(String key) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': key}),
    key,
    null,
  );
  Object info([String name = '原昵称']) => {
    'code': 0,
    'data': {'mid': 1, 'name': name, 'coins': 10, 'sign': '原签名'},
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
  setUp(() {
    requests.clear();
    Accounts.accountMode[AccountType.main.index] = login('old');
  });
  tearDown(Get.reset);
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> resolve(WidgetTester tester, int index, Object body) async {
    await tester.runAsync(() async {
      requests[index].reply.complete(body);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const EditProfilePage(),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(() => interceptor.waitForRequests(1));
    await resolve(tester, 0, info());
  }

  Future<void> finish(WidgetTester tester) async {
    final dismissed = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismissed;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('编辑失败保留草稿，在途禁止重复，成功只应用提交值并关闭原弹窗', (tester) async {
    await mount(tester);
    await tester.tap(find.text('个性签名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '保留的草稿');
    await tester.tap(find.text('确定'));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(() => interceptor.waitForRequests(2));
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, false);
    expect((requests[1].options.data as Map)['user_sign'], '保留的草稿');
    await resolve(tester, 1, {'code': -403, 'message': '资料拒绝'});
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '保留的草稿',
    );
    expect(find.text('资料拒绝'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(() => interceptor.waitForRequests(3));
    await resolve(tester, 2, {'code': 0});
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('保留的草稿'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('改名待确认先刷新核对，已生效的同名不会再次提交', (tester) async {
    await mount(tester);
    await tester.tap(find.text('昵称'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新昵称');
    await tester.tap(find.text('确定'));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(() => interceptor.waitForRequests(2));
    await resolve(tester, 1, {'damaged': true});
    expect(find.text('刷新核对'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '新昵称',
    );
    await tester.tap(find.text('刷新核对'));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(() => interceptor.waitForRequests(3));
    expect(requests.last.options.method, 'GET');
    await resolve(tester, 2, info('新昵称'));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(3));
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('同UID换凭据后旧编辑框不能向新账号提交', (tester) async {
    await mount(tester);
    await tester.tap(find.text('个性签名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '旧账号草稿');
    await tester.runAsync(() async {
      Accounts.replaceCredentials(login('new'));
      await interceptor.waitForRequests(2);
    });
    await resolve(tester, 1, info('新凭据资料'));
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(2));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('新凭据资料'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('提交后取消并离页，迟到失败不在其他页面提示', (tester) async {
    await mount(tester);
    await tester.tap(find.text('个性签名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '在途草稿');
    await tester.tap(find.text('确定'));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(() => interceptor.waitForRequests(2));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    final page = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('其他页面')),
    );
    navigator.push(page);
    await tester.pumpAndSettle();
    await resolve(tester, 1, {'code': -403, 'message': '迟到资料错误'});
    expect(find.text('其他页面'), findsOneWidget);
    expect(find.text('迟到资料错误'), findsNothing);
    navigator.pop();
    await tester.pumpAndSettle();
    await finish(tester);
  });
}
