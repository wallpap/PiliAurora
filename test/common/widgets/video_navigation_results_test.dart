import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/sub/sub_detail/media.dart';
import 'package:pili_aurora/pages/subscription_detail/widget/sub_video_card.dart';
import 'package:pili_aurora/pages/whisper_detail/widget/chat_item.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  final opened = <Map>[];
  late ValueNotifier<SubDetailItemModel> source;
  late BuildContext pageContext;
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
    opened.clear();
    for (final type in [AccountType.main, AccountType.heartbeat]) {
      Accounts.accountMode[type.index] = AnonymousAccount();
    }
    source = ValueNotifier(
      SubDetailItemModel(bvid: 'BV17x411w7KC', title: '来源视频', duration: 30),
    );
  });
  tearDown(() {
    source.dispose();
    Get.reset();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });
  Future<void> mount(WidgetTester tester, {Widget? child}) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        navigatorObservers: [routeObserver, FlutterSmartDialog.observer],
        initialRoute: '/',
        getPages: [
          GetPage(
            name: '/',
            page: () => Scaffold(
              body: Builder(
                builder: (context) {
                  pageContext = context;
                  return SizedBox(
                    width: 600,
                    height: child == null ? 180 : 450,
                    child:
                        child ??
                        ValueListenableBuilder<SubDetailItemModel>(
                          valueListenable: source,
                          builder: (_, item, _) =>
                              SubVideoCardH(videoItem: item),
                        ),
                  );
                },
              ),
            ),
          ),
          GetPage(
            name: '/videoV',
            page: () {
              opened.add(Get.arguments as Map);
              return const Scaffold(body: Text('播放页'));
            },
          ),
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
    SmartDialog.dismiss(status: .allToast);
    SmartDialog.dismiss(status: .allDialog);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  }

  Map<String, Object> video(int cid) => {
    'code': 0,
    'data': [
      {
        'cid': cid,
        'dimension': {'width': 1080, 'height': 1920, 'rotate': 0},
      },
    ],
  };
  Future<void> tap(WidgetTester tester) async {
    await tester.tap(find.text('来源视频'));
    await until(tester, () => requests.isNotEmpty);
  }

  testWidgets('实际卡片查询失败保留来源并允许重试，成功携带尺寸', (tester) async {
    await mount(tester);
    await tap(tester);
    expect(requests.single.options.extra['account'], same(Accounts.heartbeat));
    requests[0].reply.complete({'code': -404, 'message': '视频暂不可用'});
    await tester.pumpAndSettle();
    expect(find.text('视频暂不可用'), findsOneWidget);
    expect(opened, isEmpty);
    await tester.tap(find.text('来源视频'));
    await until(tester, () => requests.length == 2);
    requests[1].reply.complete(video(123));
    await until(tester, () => opened.isNotEmpty);
    expect(opened.single['cid'], 123);
    expect(opened.single['isVertical'], isTrue);
    await finish(tester);
  });

  testWidgets('空分 P 明确提示并保留卡片', (tester) async {
    await mount(tester);
    await tap(tester);
    requests[0].reply.complete({'code': 0, 'data': []});
    await tester.pumpAndSettle();
    expect(find.text('该视频暂无可播放分 P'), findsOneWidget);
    expect(opened, isEmpty);
    await finish(tester);
  });

  for (final type in [AccountType.main, AccountType.heartbeat]) {
    testWidgets('${type.name}账号替换后丢弃旧查询与错误提示', (tester) async {
      await mount(tester);
      await tap(tester);
      Accounts.accountMode[type.index] = LoginAccount(
        BiliCookieJar.fromJson({'DedeUserID': '2', 'bili_jct': 'replacement'}),
        null,
        null,
      );
      requests[0].reply.complete({'code': -404, 'message': '旧账号错误'});
      await tester.pumpAndSettle();
      expect(find.text('旧账号错误'), findsNothing);
      expect(opened, isEmpty);
      await finish(tester);
    });
  }

  testWidgets('离页返回或卡片替换后不打开旧视频', (tester) async {
    for (final replace in [false, true]) {
      await mount(tester);
      final index = requests.length;
      await tester.tap(find.text('来源视频'));
      await until(tester, () => requests.length == index + 1);
      if (replace) {
        source.value = SubDetailItemModel(title: '新来源', bvid: 'BV1xx411c7mD');
        await tester.pump();
      } else {
        Get.key.currentState!.push<void>(
          MaterialPageRoute(builder: (_) => const Scaffold(body: Text('其他页'))),
        );
        await tester.pumpAndSettle();
        Get.key.currentState!.pop();
        await tester.pumpAndSettle();
      }
      requests[index].reply.complete(video(123));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      await finish(tester);
    }
  });

  testWidgets('已知分 P 的新导航废弃仍在途旧查询', (tester) async {
    await mount(tester);
    await tap(tester);
    await PageUtils.openVideo(context: pageContext, aid: 170001, cid: 456);
    await until(tester, () => opened.isNotEmpty);
    requests[0].reply.complete(video(123));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
    expect(opened.single['cid'], 456);
    await finish(tester);
  });

  testWidgets('回调导航保留分 P 选择并安全消费同步异常', (tester) async {
    await mount(tester);
    var received = 0;
    await PageUtils.openVideo(
      context: pageContext,
      aid: 170001,
      cid: 123,
      onResolved: (cid) {
        received = cid;
        throw StateError('private-callback');
      },
    );
    await tester.pumpAndSettle();
    expect(received, 123);
    expect(find.text('视频获取失败，请重试'), findsOneWidget);
    expect(find.textContaining('private-callback'), findsNothing);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('实际私信分享缺少视频标识时安全拒绝', (tester) async {
    await mount(
      tester,
      child: ChatItem(
        item: Message(
          id: 'share',
          messageKey: 1,
          sequence: 1,
          senderId: 1,
          timestamp: 1793016000,
          type: 7,
          source: 0,
          content: StructuredMessageContent(MessageContentKind.shareV2, const {
            'source': 5,
            'title': '私信视频',
            'thumb': '',
          }),
        ),
        eInfos: null,
        isOwner: true,
        onLongPress: () {},
        onSecondaryTapUp: null,
      ),
    );
    await tester.tap(find.text('私信视频'));
    await tester.pumpAndSettle();
    expect(find.text('视频标识缺失，请刷新列表'), findsOneWidget);
    expect(requests, isEmpty);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
}
