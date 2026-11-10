import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/result.dart';
import 'package:pili_aurora/pages/share/view.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/pages/video/introduction/pgc/controller.dart';
import 'package:pili_aurora/pages/video/introduction/ugc/controller.dart';
import 'package:pili_aurora/pages/common/common_intro_controller.dart';
import 'package:pili_aurora/services/messaging/conversation.dart';
import 'package:pili_aurora/services/messaging/session.dart';
import 'package:pili_aurora/services/messaging/sharing.dart';
import 'package:pili_aurora/services/messaging/sharing_adapter.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/memory_box.dart';

class _VideoController extends GetxController implements VideoDetailController {
  @override
  String playedTimePos(bool hasParams) => '?t=12.0';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ShareController extends PgcIntroController {
  final _video = _VideoController();

  @override
  VideoDetailController get videoDetailCtr => _video;
}

class _UgcShareController extends UgcIntroController {
  final _video = _VideoController();
  @override
  VideoDetailController get videoDetailCtr => _video;
}

class _SharingAdapter extends SharingAdapter {
  @override
  Future<LoadingState<List<ShareRecipient>>> recentRecipients(
    Account account,
  ) async => const Success([
    ShareRecipient(id: 456, name: '合成收件人', avatar: ''),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Account previousAccount;

  setUpAll(() async {
    GStorage.setting = MemoryBox();
    GStorage.localCache = MemoryBox();
    await GStorage.localCache.put(LocalCacheKey.buvid, 'synthetic-buvid');
  });

  setUp(() {
    previousAccount = Accounts.main;
    Accounts.accountMode[AccountType.main.index] = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '123'}),
      null,
      null,
    );
    final session = Messaging.instance.session;
    session.resource(
      MessageSharing,
      () => MessageSharing(
        session: session,
        cache: conversationCacheFor(session),
        adapter: _SharingAdapter(),
      ),
      (_) {},
    );
  });

  tearDown(() {
    Accounts.accountMode[AccountType.main.index] = previousAccount;
    Messaging.onAccountChanged();
    Get.reset();
  });

  for (final ugc in [false, true]) {
    testWidgets('${ugc ? 'UGC' : 'PGC'} 分享菜单切号后不打开消息面板', (tester) async {
      final CommonIntroController controller = ugc
          ? (_UgcShareController()
              ..bvid = 'BV17x411w7KC'
              ..cid = 1.obs)
          : (_ShareController()
              ..pgcItem = PgcInfoModel.fromJson({
                'title': '测试',
                'type': 1,
                'episodes': [
                  {'ep_id': 123},
                ],
              })
              ..epId = 123);
      await tester.pumpWidget(
        GetMaterialApp(
          navigatorObservers: [FlutterSmartDialog.observer],
          builder: FlutterSmartDialog.init(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => controller.actionShareVideo(context),
                child: const Text('打开分享'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开分享'));
      await tester.pumpAndSettle();
      Accounts.accountMode[AccountType.main.index] = const NoAccount();
      await tester.tap(find.text('分享至消息'));
      await tester.pumpAndSettle();
      expect(find.byType(SharePanel), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('复制番剧链接包含播放进度', (tester) async {
    String? copied;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          ..setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = call.arguments['text'] as String?;
            }
            return null;
          });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final controller = _ShareController()
      ..pgcItem = PgcInfoModel.fromJson({'title': '测试', 'type': 1})
      ..epId = 123;
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => controller.actionShareVideo(context),
              child: const Text('打开分享'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开分享'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制链接'));
    await tester.pumpAndSettle();
    expect(copied, 'https://www.bilibili.com/bangumi/play/ep123?t=12.0');
    await tester.pump(const Duration(seconds: 3));
  });

  for (final fromSection in [false, true]) {
    for (final idKey in ['ep_id', 'id']) {
      testWidgets('${fromSection ? '附加内容' : '正片'}通过 $idKey 分享当前分集', (
        tester,
      ) async {
        final currentId = fromSection ? 2 : 1;
        final currentEpisode = {
          idKey: currentId,
          'show_title': '合成分集标题',
          'share_url': 'https://example.test/episodes/$currentId',
          'cover': 'https://example.test/covers/$currentId',
          if (fromSection) 'share_copy': '合成预告分享标题',
        };
        final controller = _ShareController()
          ..pgcItem = PgcInfoModel.fromJson({
            'title': '合成番剧',
            'type': 1,
            'episodes': [
              if (fromSection) {'ep_id': 1} else currentEpisode,
            ],
            'section': [
              {'title': '空分组'},
              {
                'title': '预告',
                'episodes': [
                  if (fromSection) currentEpisode else {'ep_id': 2},
                ],
              },
            ],
          })
          ..epId = currentId;
        await tester.pumpWidget(
          GetMaterialApp(
            navigatorObservers: [FlutterSmartDialog.observer],
            builder: FlutterSmartDialog.init(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => controller.actionShareVideo(context),
                  child: const Text('打开分享'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('打开分享'));
        await tester.pumpAndSettle();
        // 菜单打开后切换分集，分享内容仍属于菜单所展示的分集快照。
        controller.epId = 999;
        controller.pgcItem.title = '后来的标题';
        await tester.tap(find.text('分享至消息'));
        await tester.pumpAndSettle();

        final panel = tester.widget<SharePanel>(find.byType(SharePanel));
        final title = fromSection ? '合成预告分享标题' : '合成番剧 合成分集标题';
        expect(panel.content, {
          'id': '$currentId',
          'title': title,
          'url': currentEpisode['share_url'],
          'headline': title,
          'source': 16,
          'thumb': currentEpisode['cover'],
          'source_desc': '番剧',
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
