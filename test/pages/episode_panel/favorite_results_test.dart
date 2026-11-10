import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/episode_panel/view.dart';
import 'package:pili_aurora/pages/video/introduction/ugc/controller.dart';
import 'package:pili_aurora/models/common/episode_panel_type.dart';
import 'package:pili_aurora/models/remote/video/video_detail/section.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;

  LoginAccount login(String csrf) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': csrf}),
    null,
    null,
  )..activated = true;
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

  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> resolve(WidgetTester tester, int index, Object response) =>
      tester.runAsync(() async {
        requests[index].reply.complete(response);
        await Future<void>.delayed(Duration.zero);
      });
  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: Scaffold(
          body: EpisodePanel(
            ugcIntroController: UgcIntroController(),
            heroTag: 'test',
            type: EpisodeType.season,
            aid: 1,
            bvid: 'BV1xx411c7mD',
            cid: 1,
            cover: null,
            seasonId: 1,
            showTitle: false,
            list: [SectionItem(title: '合集', episodes: [])],
            onChangeEpisode: (_) async => false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() => interceptor.waitForRequests(1));
    await resolve(tester, 0, {
      'code': 0,
      'data': {
        'season_fav': false,
        'favorite': false,
        'like': false,
        'dislike': false,
        'coin': 0,
      },
    });
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, String tooltip) =>
      tester.runAsync(() async {
        final button = tester.widget<IconButton>(
          find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == tooltip,
          ),
        );
        button.onPressed?.call();
        await Future<void>.delayed(Duration.zero);
      });

  Future<void> finish(WidgetTester tester) async {
    final dismissed = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismissed;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  testWidgets('合集订阅防止重复提交，失败保留状态，待确认先查询', (tester) async {
    await mount(tester);
    expect(find.byTooltip('订阅'), findsOneWidget);
    await press(tester, '订阅');
    await tester.pumpAndSettle();
    await tester.runAsync(() => interceptor.waitForRequests(2));
    await press(tester, '订阅');
    await tester.pumpAndSettle();
    expect(requests, hasLength(2));
    expect(requests.last.options.extra['account'], same(Accounts.main));
    await resolve(tester, 1, {'message': 'missing code'});
    await tester.pumpAndSettle();
    expect(find.byTooltip('重试订阅状态'), findsOneWidget);
    await press(tester, '重试订阅状态');
    await tester.runAsync(() => interceptor.waitForRequests(3));
    await resolve(tester, 2, {
      'code': 0,
      'data': {
        'season_fav': true,
        'favorite': false,
        'like': false,
        'dislike': false,
        'coin': 0,
      },
    });
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消订阅'), findsOneWidget);
    await finish(tester);
  });
  testWidgets('合集切换同UID凭据后拒绝旧订阅回执，查询新状态', (tester) async {
    await mount(tester);
    await press(tester, '订阅');
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await interceptor.waitForRequests(2);
      Accounts.replaceCredentials(login('new'));
      await interceptor.waitForRequests(3);
    });
    await resolve(tester, 2, {
      'code': 0,
      'data': {
        'season_fav': false,
        'favorite': false,
        'like': false,
        'dislike': false,
        'coin': 0,
      },
    });
    await resolve(tester, 1, {'code': 0});
    await tester.pumpAndSettle();
    expect(find.byTooltip('订阅'), findsOneWidget);
    expect(find.text('订阅成功'), findsNothing);
    await finish(tester);
  });
  testWidgets('合集卸载后迟到查询不更新控件或提示', (tester) async {
    await mount(tester);
    await press(tester, '订阅');
    await tester.pumpAndSettle();
    await tester.runAsync(() => interceptor.waitForRequests(2));
    await tester.pumpWidget(const SizedBox());
    await resolve(tester, 1, {'code': 0});
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
