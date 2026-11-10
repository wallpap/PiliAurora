import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/route_aware_mixin.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/whisper_detail/view.dart';
import 'package:pili_aurora/services/messaging/conversation.dart';
import 'package:pili_aurora/services/messaging/conversation_providers.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/services/messaging/providers.dart';
import 'package:pili_aurora/services/messaging/session.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../services/messaging/messaging_fixtures.dart';
import '../../support/memory_box.dart';

class _SessionNotifier extends MessagingSessionNotifier {
  _SessionNotifier(this.session);
  final MessagingSession session;
  @override
  MessagingSession build() => session;
}

class _Adapter extends FakeConversationAdapter {
  final uploads = <String>[];
  LoadingState<UploadedMessageImage> uploadResult = const Success(
    UploadedMessageImage(
      url: 'https://test/image.png',
      width: 1,
      height: 1,
      size: 1,
      imageType: 'png',
    ),
  );
  Completer<LoadingState<UploadedMessageImage>>? pendingUpload;

  @override
  Future<LoadingState<UploadedMessageImage>> uploadImage(
    Account account,
    String path,
  ) async {
    uploads.add(path);
    return pendingUpload == null ? uploadResult : pendingUpload!.future;
  }

  @override
  Future<LoadingState<ConversationPage>> latest(
    Account account,
    ConversationTarget target,
  ) async => Success(
    ConversationPage(messages: const [], hasOlder: false, cursor: null),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const picker = MethodChannel('plugins.flutter.io/image_picker');
  const preferences = MethodChannel('plugins.flutter.io/shared_preferences');
  late MessagingSession session;
  late Conversation conversation;
  late _Adapter adapter;
  late Completer<String?> selection;
  var picks = 0;

  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
    GStorage.video = MemoryBox<dynamic>();
  });
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          preferences,
          (call) async => call.method == 'getAll' ? <String, Object>{} : true,
        );
    session = sessionFixture();
    adapter = _Adapter();
    conversation = Conversation(
      session: session,
      target: const ConversationTarget(talkerId: 456),
      adapter: adapter,
    );
    selection = Completer<String?>();
    picks = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, (call) {
          expect(call.method, 'pickImage');
          picks++;
          return selection.future;
        });
  });
  tearDown(() {
    conversation.dispose();
    session.dispose();
    Get.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(preferences, null);
  });

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messagingSessionProvider.overrideWith(
            () => _SessionNotifier(session),
          ),
          conversationProvider.overrideWith((ref, target) => conversation),
          conversationSnapshotProvider.overrideWith(
            (ref, target) => Stream.value(
              ConversationSnapshot(
                phase: ConversationPhase.ready,
                messages: const [],
                hasOlder: false,
                historyCursor: null,
                highestRenderedSequence: 0,
                acknowledgedSequence: 0,
                error: null,
              ),
            ),
          ),
        ],
        child: GetMaterialApp(
          builder: FlutterSmartDialog.init(),
          navigatorObservers: [routeObserver, FlutterSmartDialog.observer],
          home: const Scaffold(body: Text('入口')),
        ),
      ),
    );
    Get.to(
      () => const WhisperDetailPage(),
      arguments: {
        'talkerId': 456,
        'name': '私信对象',
        'face': '',
      },
    );
    await flush(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    SmartDialog.dismiss(status: .allToast);
    SmartDialog.dismiss(status: .allDialog);
    await flush(tester);
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
  }

  Future<void> choose(WidgetTester tester) async {
    await tester.tap(find.byTooltip('图片'));
    await flush(tester);
  }

  testWidgets('选图取消、插件失败及重试，互斥且隐藏插件异常', (tester) async {
    await mount(tester);
    await choose(tester);
    await choose(tester);
    expect(picks, 1);
    selection.complete(null);
    await flush(tester);
    expect(adapter.uploads, isEmpty);
    selection = Completer<String?>();
    await choose(tester);
    selection.completeError(
      PlatformException(code: 'picker', message: 'private-picker-data'),
    );
    await flush(tester);
    expect(find.text('图片操作失败，请重试'), findsOneWidget);
    expect(find.textContaining('private-picker-data'), findsNothing);
    SmartDialog.dismiss(status: .allToast);
    await flush(tester);
    selection = Completer<String?>();
    await choose(tester);
    selection.complete('selected.png');
    await flush(tester);
    expect(adapter.uploads, ['selected.png']);
    expect(adapter.sent, hasLength(1));
    expect(find.text('发送成功'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('图片上传失败保留重试，待确认提示核对聊天记录', (tester) async {
    await mount(tester);
    adapter.uploadResult = const Error('图片上传失败');
    await choose(tester);
    selection.complete('first.png');
    await flush(tester);
    expect(find.text('图片上传失败'), findsOneWidget);
    expect(adapter.sent, isEmpty);
    SmartDialog.dismiss(status: .allToast);
    await flush(tester);
    adapter
      ..uploadResult = const Success(
        UploadedMessageImage(
          url: 'https://test/image.png',
          width: 1,
          height: 1,
          size: 1,
          imageType: 'png',
        ),
      )
      ..sendRequest = () async => const UnknownResult();
    selection = Completer<String?>();
    await choose(tester);
    selection.complete('second.png');
    await flush(tester);
    expect(find.text('发送状态待确认，请核对聊天记录后再操作'), findsOneWidget);
    expect(adapter.uploads, ['first.png', 'second.png']);
    await finish(tester);
  });

  testWidgets('选图期间离页返回使旧选择失效，随后可重新选择', (tester) async {
    await mount(tester);
    await choose(tester);
    Get.to(() => const Scaffold(body: Text('其他页面')));
    await flush(tester);
    Get.back();
    await flush(tester);
    selection.complete('stale.png');
    await flush(tester);
    expect(adapter.uploads, isEmpty);
    expect(find.text('发送成功'), findsNothing);
    selection = Completer<String?>();
    await choose(tester);
    selection.complete('current.png');
    await flush(tester);
    expect(adapter.uploads, ['current.png']);
    await finish(tester);
  });

  testWidgets('上传迟到结果只关闭自己的加载，离页后不提示成功', (tester) async {
    await mount(tester);
    adapter.pendingUpload = Completer();
    await choose(tester);
    selection.complete('uploading.png');
    await flush(tester);
    expect(adapter.uploads, ['uploading.png']);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(
              IconButton,
              Icons.add_photo_alternate_outlined,
            ),
          )
          .onPressed,
      isNull,
    );
    Get.to(() => const Scaffold(body: Text('其他页面')));
    await flush(tester);
    SmartDialog.show<void>(
      tag: 'other-operation',
      builder: (_) => const Text('其他操作加载中'),
    );
    await flush(tester);
    adapter.pendingUpload!.complete(adapter.uploadResult);
    await flush(tester);
    expect(find.text('其他操作加载中'), findsOneWidget);
    expect(find.text('发送成功'), findsNothing);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('选图结果返回前 Session 失效时不上传或发送', (tester) async {
    await mount(tester);
    await choose(tester);
    session.dispose();
    selection.complete('old-account.png');
    await flush(tester);
    expect(adapter.uploads, isEmpty);
    expect(adapter.sent, isEmpty);
    expect(find.text('发送成功'), findsNothing);
    await finish(tester);
  });

  for (final close in [false, true]) {
    testWidgets('选图异常不交付旧 Session 或关闭页面（关闭：$close）', (tester) async {
      selection = Completer<String?>();
      await mount(tester);
      await choose(tester);
      if (close) {
        Get.back();
        await flush(tester);
      } else {
        session.dispose();
      }
      selection.completeError(
        PlatformException(code: 'stale', message: 'private-stale-data'),
      );
      await flush(tester);
      expect(adapter.uploads, isEmpty);
      expect(find.text('图片操作失败，请重试'), findsNothing);
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  }
}
