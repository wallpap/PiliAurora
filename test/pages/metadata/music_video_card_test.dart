import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/music/bgm_recommend_list.dart';
import 'package:pili_aurora/pages/music/widget/music_video_card_h.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  var opened = 0;
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
    opened = 0;
    Accounts.accountMode[AccountType.heartbeat.index] = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'fixture'}),
      null,
      null,
    );
  });
  tearDown(Get.reset);
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> mount(
    WidgetTester tester, {
    bool missingId = false,
    int? cid,
  }) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        navigatorObservers: [routeObserver],
        initialRoute: '/',
        getPages: [
          GetPage(
            name: '/',
            page: () => Scaffold(
              body: SizedBox(
                width: 600,
                height: 180,
                child: MusicVideoCardH(
                  videoItem: BgmRecommend.fromJson({
                    if (!missingId) 'bvid': 'BV17x411w7KC',
                    'cid': ?cid,
                  }),
                ),
              ),
            ),
          ),
          GetPage(
            name: '/videoV',
            page: () {
              opened++;
              return const Scaffold(body: Text('播放页'));
            },
          ),
          GetPage(name: '/other', page: () => const Scaffold()),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 300 && !ready(); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(ready(), isTrue);
  }

  Future<void> finish(WidgetTester tester) async {
    final dismiss = SmartDialog.dismiss(status: SmartStatus.allToast);
    await tester.pumpAndSettle();
    await dismiss;
    await tester.pumpWidget(const SizedBox());
  }

  Future<void> tap(WidgetTester tester, int count) async {
    await tester.tap(find.text('未命名视频'));
    await until(tester, () => requests.length == count);
  }

  testWidgets('缺少可选字段正常展示，缺少标识时提示刷新且不发请求', (tester) async {
    await mount(tester, missingId: true);
    expect(find.text('未知创作者'), findsOneWidget);
    await tester.tap(find.text('未命名视频'));
    await tester.pumpAndSettle();
    expect(find.text('视频标识缺失，请刷新列表'), findsOneWidget);
    expect(requests, isEmpty);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
  testWidgets('空分 P 显式提示并允许再次查询', (tester) async {
    await mount(tester);
    await tap(tester, 1);
    requests[0].reply.complete({'code': 0, 'data': []});
    await until(tester, () => find.text('该视频暂无可播放分 P').evaluate().isNotEmpty);
    expect(opened, 0);
    await tap(tester, 2);
    requests[1].reply.complete({
      'code': 0,
      'data': [
        {'cid': 123},
      ],
    });
    await until(tester, () => opened == 1);
    await finish(tester);
  });
  for (final accountChange in [true, false]) {
    testWidgets('${accountChange ? '换账号' : '离页返回'}后不交付旧查询结果', (tester) async {
      await mount(tester);
      await tap(tester, 1);
      if (accountChange) {
        Accounts.accountMode[AccountType.heartbeat.index] = LoginAccount(
          BiliCookieJar.fromJson({
            'DedeUserID': '1',
            'bili_jct': 'replacement',
          }),
          null,
          null,
        );
      } else {
        Get.toNamed('/other');
        await tester.pumpAndSettle();
        Get.back<void>();
        await tester.pumpAndSettle();
      }
      requests[0].reply.complete({
        'code': 0,
        'data': [
          {'cid': 123},
        ],
      });
      await tester.pumpAndSettle();
      expect(opened, 0);
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  }
  testWidgets('失败显示服务提示，再次点击能重试', (tester) async {
    await mount(tester);
    await tap(tester, 1);
    requests[0].reply.complete({'code': -404, 'message': '视频暂不可用'});
    await until(tester, () => find.text('视频暂不可用').evaluate().isNotEmpty);
    await tap(tester, 2);
    requests[1].reply.complete({
      'code': 0,
      'data': [
        {'cid': 123},
      ],
    });
    await until(tester, () => opened == 1);
    await finish(tester);
  });
  testWidgets('无效 cid 重新查询，响应仍无效时不跳转且能重试', (tester) async {
    await mount(tester, cid: 0);
    await tap(tester, 1);
    requests[0].reply.complete({
      'code': 0,
      'data': [
        {'cid': 0},
      ],
    });
    await until(tester, () => find.text('响应数据解析失败，请重试').evaluate().isNotEmpty);
    expect(opened, 0);
    await tap(tester, 2);
    requests[1].reply.complete({
      'code': 0,
      'data': [
        {'cid': 123},
      ],
    });
    await until(tester, () => opened == 1);
    await finish(tester);
  });
}
