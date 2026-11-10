import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/dialog/video_feedback.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/home/rcmd/result.dart';
import 'package:pili_aurora/pages/search/widgets/search_text.dart';
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
    BiliCookieJar.fromJson({'DedeUserID': '$id'}),
    'fixture-key',
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
    Accounts.accountMode[AccountType.recommend.index] = account(1);
  });
  tearDown(Get.reset);
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> mount(
    WidgetTester tester, {
    VoidCallback? onRemove,
    bool Function()? isCurrent,
  }) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: Text('列表')),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    showDialog<void>(
      context: tester.element(find.text('列表')),
      builder: (_) => VideoFeedbackDialog(
        item: RcmdVideoItemAppModel.fromJson({
          'param': '1',
          'title': '视频',
          'card_goto': 'av',
          'three_point_v2': [
            {
              'type': 'dislike',
              'reasons': [
                {'id': 2, 'name': '减少推荐'},
              ],
            },
          ],
        }),
        isCurrent: isCurrent ?? () => true,
        onRemove: onRemove,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    final dismissal = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismissal;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester) => tester.runAsync(() async {
    tester.widget<SearchText>(find.byType(SearchText)).onTap!('减少推荐');
    await interceptor.waitForRequests(1);
  });

  Future<void> resolve(WidgetTester tester, int index, Object body) =>
      tester.runAsync(() async {
        requests[index].reply.complete(body);
        // 请求在真实异步区发起，响应也先排空该事件循环再推进模拟动画。
        await Future<void>.delayed(Duration.zero);
      });

  testWidgets('反馈在弹窗内提交且拒绝并发，缺少 toast 仍确认成功，列表回调失败不改写结果', (tester) async {
    var removed = 0;
    await mount(
      tester,
      onRemove: () {
        removed++;
        throw StateError('fixture callback');
      },
    );
    final action = tester.widget<SearchText>(find.byType(SearchText)).onTap!;
    await tester.runAsync(() async {
      action('减少推荐');
      action('减少推荐');
      await interceptor.waitForRequests(1);
    });
    await tester.pump();
    expect(find.text('提交中…'), findsOneWidget);
    await resolve(tester, 0, {'code': 0});
    await tester.pumpAndSettle();
    expect(find.byType(VideoFeedbackDialog), findsNothing);
    expect(find.text('反馈成功'), findsOneWidget);
    expect(removed, 1);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('反馈拒绝后保留弹窗，撤销成功关闭所属弹窗且不移除卡片', (tester) async {
    var removed = 0;
    await mount(tester, onRemove: () => removed++);
    await submit(tester);
    await resolve(tester, 0, {'code': -403, 'message': '拒绝反馈'});
    await tester.pumpAndSettle();
    expect(find.byType(VideoFeedbackDialog), findsOneWidget);
    expect(removed, 0);
    await tester.runAsync(() async {
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed!();
      await interceptor.waitForRequests(2);
    });
    await resolve(tester, 1, {'code': 0});
    await tester.pumpAndSettle();
    expect(find.byType(VideoFeedbackDialog), findsNothing);
    expect(removed, 0);
    await finish(tester);
  });

  testWidgets('切号或来源失效后的迟到成功不移除卡片或关闭新页面', (tester) async {
    var removed = 0;
    var current = true;
    await mount(tester, onRemove: () => removed++, isCurrent: () => current);
    await submit(tester);
    current = false;
    Accounts.accountMode[AccountType.recommend.index] = account(2);
    Navigator.of(tester.element(find.byType(VideoFeedbackDialog))).pop();
    await tester.pumpAndSettle();
    Get.to(() => const Scaffold(body: Text('新页面')));
    await tester.pumpAndSettle();
    await resolve(tester, 0, {'code': 0});
    await tester.pumpAndSettle();
    expect(find.text('新页面'), findsOneWidget);
    expect(removed, 0);
    await finish(tester);
  });
}
