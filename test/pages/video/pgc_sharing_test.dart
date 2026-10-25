import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_info_model/result.dart';
import 'package:pili_aurora/pages/share/view.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/pages/video/introduction/pgc/controller.dart';
import 'package:pili_aurora/services/messaging/conversation.dart';
import 'package:pili_aurora/services/messaging/session.dart';
import 'package:pili_aurora/services/messaging/sharing.dart';
import 'package:pili_aurora/services/messaging/sharing_adapter.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

class _SettingsBox implements Box<dynamic> {
  final _values = <dynamic, dynamic>{};

  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      _values[key] ?? defaultValue;

  @override
  Future<void> put(dynamic key, dynamic value) async {
    _values[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _VideoController extends GetxController implements VideoDetailController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ShareController extends PgcIntroController {
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
    GStorage.setting = _SettingsBox();
    GStorage.localCache = _SettingsBox();
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
