import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/music/controller.dart';
import 'package:pili_aurora/pages/music/view.dart';
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
  final account = LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'synthetic-csrf'}),
    null,
    null,
  );
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox({
      LocalCacheKey.mixinKey: 'synthetic',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() {
    Accounts.accountMode[AccountType.main.index] = account;
    requests.clear();
  });
  tearDown(Get.reset);
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> until(WidgetTester tester, bool Function() ready) async {
    final deadline = tester.binding.clock.now().add(const Duration(seconds: 3));
    while (!ready() && tester.binding.clock.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(ready(), isTrue);
    await tester.pump();
  }

  Future<void> mount(
    WidgetTester tester, [
    String route = '/music?musicId=track',
  ]) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(),
        getPages: [
          GetPage(name: '/music', page: () => const MusicDetailPage()),
        ],
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    Get.toNamed(route);
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('等待音乐请求时显示加载，失败显示提示并能重新请求', (tester) async {
    await mount(tester);
    await until(tester, () => requests.length == 1);
    expect(find.byWidget(m3eLoading), findsOneWidget);
    requests[0].reply.complete({'code': -403, 'message': '音乐暂不可用'});
    final controller = Get.find<MusicDetailController>(tag: 'track');
    await until(tester, () => controller.infoState.value is Error);
    expect(find.text('音乐暂不可用'), findsOneWidget);
    final retry = controller.getMusicDetail();
    await until(tester, () => requests.length == 2);
    expect(find.byWidget(m3eLoading), findsOneWidget);
    requests[1].reply.complete({
      'code': 0,
      'data': {'music_title': 'sample'},
    });
    await until(tester, () => controller.infoState.value is Success);
    await retry;
    await finish(tester);
  });

  testWidgets('缺少封面、评论与创作者字段仍能显示音乐卡片', (tester) async {
    await mount(tester);
    await until(tester, () => requests.length == 1);
    requests[0].reply.complete({
      'code': 0,
      'data': {
        'music_title': 'sample',
        'artists_list': [<String, dynamic>{}],
      },
    });
    final controller = Get.find<MusicDetailController>(tag: 'track');
    await until(tester, () => controller.infoState.value is Success);
    await tester.pumpAndSettle();
    expect(find.text('sample'), findsWidgets);
    expect(find.text('未知创作者'), findsOneWidget);
    expect(controller.canComment, isFalse);
    expect(find.byTooltip('评论'), findsNothing);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('点赞在途显示处理中并禁用按钮，待确认结果不伪造点赞状态', (tester) async {
    await mount(tester);
    await until(tester, () => requests.length == 1);
    requests[0].reply.complete({
      'code': 0,
      'data': {
        'music_title': 'sample',
        'wish_listen': false,
      },
    });
    final controller = Get.find<MusicDetailController>(tag: 'track');
    await until(tester, () => controller.infoState.value is Success);
    await tester.pumpAndSettle();
    await tester.tap(find.text('点赞'));
    await until(tester, () => requests.length == 2);
    expect(find.text('处理中'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '处理中'))
          .onPressed,
      isNull,
    );
    requests[1].reply.complete({'message': 'missing status'});
    await until(tester, () => !controller.updatingWish);
    expect(controller.infoState.value.data.wishListen, isFalse);
    expect(find.textContaining('操作结果待确认'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('缺少路由音乐标识显示可读失败，避免空断言和网络请求', (tester) async {
    await mount(tester, '/music');
    final controller = Get.find<MusicDetailController>(tag: '');
    await until(tester, () => controller.infoState.value is Error);
    expect(find.textContaining('音乐标识无效'), findsOneWidget);
    expect(requests, isEmpty);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
}
