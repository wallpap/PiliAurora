import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/flutter/text_field/controller.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/live/live_emote/emoticon.dart';
import 'package:pili_aurora/pages/common/publish/common_rich_text_pub_page.dart';
import 'package:pili_aurora/pages/live_emote/view.dart';
import 'package:pili_aurora/pages/live_room/controller.dart';
import 'package:pili_aurora/pages/live_room/send_danmaku/view.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

class _Room implements LiveRoomController {
  @override
  int roomId = 12;
  @override
  bool isClosed = false;
  @override
  List<RichTextItem>? savedDanmaku = [RichTextItem.fromStart('原弹幕')];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  Account account(int id) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$id', 'bili_jct': 'fixture-$id'}),
    null,
    null,
  );
  final original = account(1);
  final replacement = account(2);
  setUpAll(() {
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
  });
  setUp(() async {
    Accounts.accountMode[AccountType.main.index] = original;
    await GStorage.localCache.putAll({
      LocalCacheKey.mixinKey: 'synthetic',
      LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
    });
    requests.clear();
  });
  tearDown(() {
    for (final request in requests) {
      if (!request.reply.isCompleted) {
        request.reply.complete({'code': -1, 'message': 'closed'});
      }
    }
    Get.reset();
  });
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
  });

  Future<void> until(WidgetTester tester, bool Function() condition) async {
    final deadline = tester.binding.clock.now().add(const Duration(seconds: 3));
    while (!condition() && tester.binding.clock.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(condition(), isTrue);
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  Future<CommonRichTextPubPageState> openSender(
    WidgetTester tester,
    _Room owner,
    List<String> drafts,
  ) async {
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: Scaffold(
          body: TextButton(
            onPressed: () => Get.to<void>(
              () => Scaffold(
                body: LiveSendDmPanel(
                  liveRoomController: owner,
                  autofocus: false,
                  items: owner.savedDanmaku,
                  onSave: (items) =>
                      drafts.add(items.map((e) => e.rawText).join()),
                ),
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    await tester.tap(find.text('打开'));
    await settle(tester);
    return tester.state<CommonRichTextPubPageState>(
      find.byType(LiveSendDmPanel),
    );
  }

  void edit(CommonRichTextPubPageState state, String text) {
    state.editController.items
      ..clear()
      ..add(RichTextItem.fromStart(text));
    state.editController.text = text;
    state.onChanged(text);
  }

  testWidgets('直播发送防重复，成功后保留等待期间编辑的新草稿', (tester) async {
    final owner = _Room();
    final drafts = <String>[];
    final state = await openSender(tester, owner, drafts);
    final publish = state.onPublish();
    await state.onPublish();
    await until(tester, () => requests.length == 1);
    expect(requests.single.options.path, Api.sendLiveMsg);
    expect(requests.single.options.extra['account'], same(original));
    final data = requests.single.options.data as FormData;
    expect(Map.fromEntries(data.fields)['msg'], '原弹幕');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    edit(state, '新草稿');
    requests.single.reply.complete({'code': 0});
    await settle(tester);
    await publish;
    expect(find.byType(LiveSendDmPanel), findsOneWidget);
    expect(state.editController.rawText, '新草稿');
    expect(owner.savedDanmaku, isNotNull);
    Get.back<void>();
    await settle(tester);
    expect(drafts.single, '新草稿');
    await finish(tester);
  });

  testWidgets('关闭直播发送面板后的成功不关闭新页面或清除草稿', (tester) async {
    final owner = _Room();
    final drafts = <String>[];
    final state = await openSender(tester, owner, drafts);
    final publish = state.onPublish();
    await until(tester, () => requests.length == 1);
    Get.back<void>();
    await settle(tester);
    unawaited(Get.to<void>(() => const Scaffold(body: Text('新页面'))));
    await settle(tester);
    requests.single.reply.complete({'code': 0});
    await settle(tester);
    await publish;
    expect(find.text('新页面'), findsOneWidget);
    expect(drafts.single, '原弹幕');
    expect(owner.savedDanmaku, isNotNull);
    expect(find.text('发送成功'), findsNothing);
    await finish(tester);
  });

  testWidgets('直播发送切号或换房间后拒绝旧结果', (tester) async {
    final owner = _Room();
    final state = await openSender(tester, owner, []);
    var publish = state.onPublish();
    await until(tester, () => requests.length == 1);
    Accounts.accountMode[AccountType.main.index] = replacement;
    requests[0].reply.complete({'code': 0});
    await settle(tester);
    await publish;
    expect(find.byType(LiveSendDmPanel), findsOneWidget);
    expect(state.hasPub, isFalse);
    expect(find.text('发送成功'), findsNothing);
    publish = state.onPublish();
    await until(tester, () => requests.length == 2);
    expect(requests.last.options.extra['account'], same(replacement));
    owner.roomId = 34;
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await publish;
    expect(find.byType(LiveSendDmPanel), findsOneWidget);
    expect(owner.savedDanmaku, isNotNull);
    expect(find.text('发送成功'), findsNothing);
    await state.onPublish();
    expect(requests, hasLength(2));
    await finish(tester);
  });

  testWidgets('直播发送待确认保留草稿，明确成功才关闭所属面板', (tester) async {
    final owner = _Room();
    final drafts = <String>[];
    final state = await openSender(tester, owner, drafts);
    var publish = state.onPublish();
    await until(tester, () => requests.length == 1);
    requests.single.reply.complete({'code': '0'});
    await settle(tester);
    await publish;
    expect(state.editController.rawText, '原弹幕');
    expect(state.hasPub, isFalse);
    expect(find.text('操作结果待确认，请先核对后再操作'), findsOneWidget);
    publish = state.onPublish();
    await until(tester, () => requests.length == 2);
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await publish;
    expect(find.byType(LiveSendDmPanel), findsNothing);
    expect(owner.savedDanmaku, isNull);
    expect(drafts, isEmpty);
    await finish(tester);
  });

  testWidgets('直播表情直接发送与文本共用在途状态，并保留未发送文本', (tester) async {
    final owner = _Room();
    final drafts = <String>[];
    final state = await openSender(tester, owner, drafts);
    final panel = (state.customPanel as DecoratedBox).child as LiveEmotePanel;
    final emote = Emoticon(emoticonUnique: 'synthetic_emote');
    panel.onSendEmoticonUnique(emote);
    panel.onSendEmoticonUnique(emote);
    await state.onPublish();
    await until(tester, () => requests.length == 1);
    final data = Map.fromEntries(
      (requests.single.options.data as FormData).fields,
    );
    expect(data['msg'], 'synthetic_emote');
    expect(data['dm_type'], '1');
    requests.single.reply.complete({'code': 0});
    await settle(tester);
    expect(find.byType(LiveSendDmPanel), findsOneWidget);
    expect(state.editController.rawText, '原弹幕');
    Get.back<void>();
    await settle(tester);
    expect(drafts.single, '原弹幕');
    await finish(tester);
  });
}
