import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/app_scheme.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/request_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/url_utils.dart';

import '../support/controlled_interceptor.dart';
import '../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor(
    headers: Headers.fromMap({
      'location': ['https://www.bilibili.com/video/av123'],
    }),
  );
  final requests = interceptor.requests;
  final openedVideos = <Map>[];
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
    Accounts.accountMode[AccountType.main.index] = AnonymousAccount();
    requests.clear();
    openedVideos.clear();
  });
  tearDown(Get.reset);
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    GetMaterialApp(
      builder: FlutterSmartDialog.init(),
      navigatorObservers: [routeObserver, FlutterSmartDialog.observer],
      initialRoute: '/',
      getPages: [
        GetPage(
          name: '/',
          page: () => const Scaffold(body: Text('来源页面')),
        ),
        GetPage(
          name: '/videoV',
          page: () {
            openedVideos.add(Get.arguments as Map);
            return const Scaffold(body: Text('视频页面'));
          },
        ),
        GetPage(
          name: '/other',
          page: () => const Scaffold(body: Text('其他页面')),
        ),
      ],
    ),
  );
  Future<void> until(WidgetTester tester, bool Function() ready) async {
    final deadline = tester.binding.clock.now().add(const Duration(seconds: 3));
    while (!ready() && tester.binding.clock.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(ready(), true);
  }

  Future<void> complete(
    WidgetTester tester,
    Future<void> operation,
    int index,
    Object body,
  ) async {
    var done = false;
    unawaited(operation.whenComplete(() => done = true));
    requests[index].reply.complete(body);
    await until(tester, () => done);
    await operation;
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> finish(WidgetTester tester) async {
    final dismiss = SmartDialog.dismiss(status: SmartStatus.allDialog);
    await tester.pumpAndSettle();
    await dismiss;
    final toasts = SmartDialog.dismiss(status: SmartStatus.allToast);
    await tester.pumpAndSettle();
    await toasts;
    await tester.pumpWidget(const SizedBox());
  }

  Map<String, Object> video(int cid) => {
    'code': 0,
    'data': [
      {'cid': cid},
    ],
  };
  const failed = {'code': -404, 'message': '迟到错误'};

  testWidgets('实名查询只交付最近操作，当前成功可关闭弹窗', (tester) async {
    await mount(tester);
    final first = RequestUtils.showUserRealName('1');
    await until(tester, () => requests.length == 1);
    final latest = RequestUtils.showUserRealName('2');
    await until(tester, () => requests.length == 2);
    await complete(tester, first, 0, failed);
    expect(find.text('迟到错误'), findsNothing);
    await complete(tester, latest, 1, {
      'code': 0,
      'data': {'name': '当前实名'},
    });
    expect(find.text('当前实名'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('来源页面'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('实名查询离页再返回后丢弃迟到成功', (tester) async {
    await mount(tester);
    final operation = RequestUtils.showUserRealName('1');
    await until(tester, () => requests.length == 1);
    Get.toNamed<void>('/other');
    await tester.pumpAndSettle();
    Get.back<void>();
    await tester.pumpAndSettle();
    await complete(tester, operation, 0, {
      'code': 0,
      'data': {'name': '旧页面实名'},
    });
    expect(find.text('旧页面实名'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    await finish(tester);
  });

  testWidgets('实名查询账号替换后不显示旧响应', (tester) async {
    await mount(tester);
    final account = Accounts.main;
    final operation = RequestUtils.showUserRealName('1');
    await until(tester, () => requests.length == 1);
    expect(requests.single.options.extra['account'], same(account));
    Accounts.accountMode[AccountType.main.index] = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '2', 'bili_jct': 'fixture'}),
      null,
      null,
    );
    await complete(tester, operation, 0, failed);
    expect(find.text('迟到错误'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    await finish(tester);
  });

  testWidgets('旧视频查询先失败不提示、不关闭新查询或其他任务的加载', (tester) async {
    await mount(tester);
    SmartDialog.showLoading(msg: '其他任务');
    final first = PiliScheme.videoPush(123, null);
    await until(tester, () => requests.length == 1);
    final latest = PiliScheme.videoPush(124, null);
    await until(tester, () => requests.length == 2);
    await complete(tester, first, 0, failed);
    expect(find.text('迟到错误'), findsNothing);
    expect(
      SmartDialog.checkExist(dialogTypes: {SmartAllDialogType.loading}),
      true,
    );
    expect(find.text('获取中...'), findsOneWidget);
    await complete(tester, latest, 1, video(42));
    expect(openedVideos, hasLength(1));
    expect(openedVideos.single['aid'], 124);
    expect(find.text('获取中...'), findsNothing);
    expect(
      SmartDialog.checkExist(dialogTypes: {SmartAllDialogType.loading}),
      true,
    );
    final loading = SmartDialog.dismiss(status: SmartStatus.loading);
    await tester.pumpAndSettle();
    await loading;
    await finish(tester);
  });

  testWidgets('新视频先完成后，旧成功回包不会再次导航', (tester) async {
    await mount(tester);
    final first = PiliScheme.videoPush(123, null);
    await until(tester, () => requests.length == 1);
    final latest = PiliScheme.videoPush(124, null);
    await until(tester, () => requests.length == 2);
    await complete(tester, latest, 1, video(42));
    await complete(tester, first, 0, video(43));
    expect(openedVideos, hasLength(1));
    expect(openedVideos.single['cid'], 42);
    await finish(tester);
  });

  testWidgets('当前视频空结果明确提示，并关闭自己的加载', (tester) async {
    await mount(tester);
    final operation = PiliScheme.videoPush(123, null);
    await until(tester, () => requests.length == 1);
    await complete(tester, operation, 0, {'code': 0, 'data': []});
    expect(find.text('视频暂无可播放内容'), findsOneWidget);
    expect(find.text('获取中...'), findsNothing);
    expect(openedVideos, isEmpty);
    await finish(tester);
  });

  testWidgets('离页后即使返回同一页面，旧视频查询仍然失效', (tester) async {
    await mount(tester);
    final operation = PiliScheme.videoPush(123, null);
    await until(tester, () => requests.length == 1);
    Get.toNamed('/other');
    await tester.pump(const Duration(milliseconds: 500));
    Get.back();
    await tester.pump(const Duration(milliseconds: 500));
    await complete(tester, operation, 0, video(42));
    expect(openedVideos, isEmpty);
    expect(find.text('来源页面'), findsOneWidget);
    expect(find.text('获取中...'), findsNothing);
    await finish(tester);
  });

  for (final (name, start) in <(String, Future<void> Function())>[
    ('动态', () => PageUtils.pushDynFromId(id: '1')),
    ('番剧', () => PageUtils.viewPgc(seasonId: 1)),
    ('课程', () => PageUtils.viewPugv(seasonId: 1)),
    ('匹配视频链接', () => UrlUtils.matchUrlPush('av123', '')),
    (
      '播放列表',
      () async {
        await PiliScheme.routePushFromUrl(
          'https://m.bilibili.com/playlist/pl123?bvid=BV17x411w7KC',
        );
      },
    ),
  ]) {
    testWidgets('$name离页后的错误回包不打扰新页面', (tester) async {
      await mount(tester);
      final operation = start();
      await until(tester, () => requests.length == 1);
      Get.toNamed('/other');
      await tester.pump(const Duration(milliseconds: 500));
      SmartDialog.showLoading(msg: '新页面任务');
      await complete(tester, operation, 0, failed);
      expect(find.text('迟到错误'), findsNothing);
      expect(find.text('其他页面'), findsOneWidget);
      expect(
        SmartDialog.checkExist(dialogTypes: {SmartAllDialogType.loading}),
        true,
      );
      final loading = SmartDialog.dismiss(status: SmartStatus.loading);
      await tester.pumpAndSettle();
      await loading;
      await finish(tester);
    });
  }

  testWidgets('短链接重定向迟到后不再查询视频或回退网页', (tester) async {
    await mount(tester);
    var done = false;
    var handled = false;
    final operation = PiliScheme.routePushFromUrl('https://b23.tv/short')
        .then((value) {
          handled = value;
          done = true;
        });
    await until(tester, () => requests.length == 1);
    Get.toNamed('/other');
    await tester.pump(const Duration(milliseconds: 500));
    requests.single.reply.complete('');
    await until(tester, () => done);
    await operation;
    expect(handled, true);
    expect(requests, hasLength(1));
    expect(openedVideos, isEmpty);
    expect(find.text('其他页面'), findsOneWidget);
    await finish(tester);
  });
}
