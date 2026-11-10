import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/dialog/report_member.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  Account account(int id) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$id', 'bili_jct': 'csrf-$id'}),
    null,
    null,
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
    requests.clear();
    Accounts.accountMode[AccountType.main.index] = account(1);
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
        home: const Scaffold(body: Text('空间')),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    showMemberReportDialog(
      tester.element(find.text('空间')),
      name: '成员',
      mid: 42,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('头像违规'));
    await tester.tap(find.text('色情低俗'));
    await tester.pump();
  }

  TextButton confirm(WidgetTester tester) => tester.widget<TextButton>(
    find.widgetWithText(TextButton, '确定'),
  );
  Future<void> submit(WidgetTester tester, int count) =>
      tester.runAsync(() async {
        confirm(tester).onPressed!();
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

  testWidgets('举报等待确认且拒绝重复提交，成功后关闭所属弹窗', (tester) async {
    await mount(tester);
    final send = confirm(tester).onPressed!;
    await tester.runAsync(() async {
      send();
      send();
      await interceptor.waitForRequests(1);
    });
    await tester.pump();
    expect(find.text('提交中'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    final tile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('头像违规'),
        matching: find.byType(ListTile),
      ),
    );
    expect(tile.onTap, isNull);
    expect((requests.single.options.data as Map)['reason'], '1');
    expect((requests.single.options.data as Map)['reason_v2'], 1);
    expect((requests.single.options.data as Map)['csrf'], 'csrf-1');
    await resolve(tester, 0, {'status': true});
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('举报成功'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('明确拒绝和待确认均保留举报选项，重试仍发送原选择', (tester) async {
    await mount(tester);
    await submit(tester, 1);
    await resolve(tester, 0, {'status': false, 'message': '拒绝举报'});
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('拒绝举报'), findsOneWidget);
    expect(find.byIcon(Icons.check_box), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    await submit(tester, 2);
    await resolve(tester, 1, {'code': 0});
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('操作结果待确认'), findsOneWidget);
    expect(requests.last.options.data, requests.first.options.data);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('关闭后的迟到成功不会关闭后来页面或显示成功提示', (tester) async {
    await mount(tester);
    await submit(tester, 1);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    Get.to(() => const Scaffold(body: Text('新页面')));
    await tester.pumpAndSettle();
    await resolve(tester, 0, {'status': true});
    await tester.pumpAndSettle();
    expect(find.text('新页面'), findsOneWidget);
    expect(find.text('举报成功'), findsNothing);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('切号后的迟到拒绝不提示，旧弹窗禁止再次向新账号提交', (tester) async {
    await mount(tester);
    await submit(tester, 1);
    Accounts.accountMode[AccountType.main.index] = account(2);
    await resolve(tester, 0, {'status': false, 'message': '旧账号拒绝'});
    await tester.pumpAndSettle();
    expect(find.text('旧账号拒绝'), findsNothing);
    expect(find.byType(AlertDialog), findsOneWidget);
    confirm(tester).onPressed!();
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));
    expect(find.text('账号已切换，请重新打开举报'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
}
