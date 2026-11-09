import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/flutter/text_field/controller.dart'
    show RichTextItem;
import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo;
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/pages/common/publish/common_rich_text_pub_page.dart';
import 'package:pili_aurora/pages/video/reply/controller.dart';
import 'package:pili_aurora/pages/video/reply/widgets/reply_item_grpc.dart';
import 'package:pili_aurora/pages/video/reply_new/view.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/controlled_interceptor.dart';
import '../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final interceptor = ControlledInterceptor();
  final requests = interceptor.requests;
  LoginAccount account(int mid) => LoginAccount(
    BiliCookieJar.fromJson({'DedeUserID': '$mid', 'bili_jct': 'fixture-$mid'}),
    null,
    null,
  );
  final original = account(1);
  final replacement = account(2);
  late Directory directory;
  late File image;

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/shared_preferences'),
          (call) async => call.method == 'getAll' ? <String, Object>{} : true,
        );
    GStorage.setting = MemoryBox();
    GStorage.video = MemoryBox();
    GStorage.localCache = MemoryBox();
    GStorage.userInfo = MemoryBox();
    GStorage.reply = null;
    Request();
    Request.dio.interceptors
      ..clear()
      ..add(interceptor);
    directory = await Directory.systemTemp.createTemp('pili-reply-');
    image = await File('${directory.path}/pixel.png').writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
      ),
    );
  });
  setUp(() {
    Accounts.accountMode[AccountType.main.index] = original;
    requests.clear();
  });
  tearDown(Get.reset);
  tearDownAll(() async {
    Request.dio.close(force: true);
    await interceptor.close();
    await image.delete();
    await directory.delete();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  Future<void> until(WidgetTester tester, bool Function() condition) async {
    final end = tester.binding.clock.now().add(const Duration(seconds: 3));
    while (!condition() && tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(condition(), isTrue);
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    final dismissal = SmartDialog.dismiss(status: .allToast);
    await tester.pumpAndSettle();
    await dismissal;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  Future<BuildContext> mount(WidgetTester tester, [ReplyPage? panel]) async {
    late BuildContext owner;
    await tester.pumpWidget(
      GetMaterialApp(
        builder: FlutterSmartDialog.init(),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              owner = context;
              return const Text('原页面');
            },
          ),
        ),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    if (panel != null) {
      Get.to(() => Scaffold(body: panel));
      await settle(tester);
    }
    return owner;
  }

  ReplyPage page({ValueChanged<ReplyInfo?>? onSuccess}) => ReplyPage(
    oid: 1,
    root: 2,
    parent: 3,
    replyType: 1,
    onSuccess: onSuccess,
  );
  CommonRichTextPubPageState state(WidgetTester tester) =>
      tester.state<CommonRichTextPubPageState>(find.byType(ReplyPage));
  void draft(CommonRichTextPubPageState editor, String text) {
    editor.editController.items
      ..clear()
      ..add(RichTextItem.fromStart(text));
    editor.editController.text = text;
  }

  Object uploaded() => {
    'code': 0,
    'data': {
      'image_url': 'https://example.invalid/image.png',
      'image_width': 1,
      'image_height': 1,
    },
  };

  testWidgets('评论编辑器保留楼中楼根 ID，草稿按完整目标隔离', (tester) async {
    await mount(tester);
    final controller = VideoReplyController(
      aid: 1,
      videoType: VideoType.ugc,
      heroTag: 'reply-editor',
    )..onInit();
    final parent = ReplyInfo(
      id: Int64(3),
      oid: Int64.ONE,
      type: Int64.ONE,
      root: Int64(2),
    );
    controller.onReply(parent);
    await settle(tester);
    final target = tester.widget<ReplyPage>(find.byType(ReplyPage));
    expect(target.root, 2);
    expect(target.parent, 3);
    draft(state(tester), '草稿');
    Get.back();
    await settle(tester);
    expect(controller.savedReplies, hasLength(1));
    controller.onReply(
      ReplyInfo(id: Int64(2), oid: Int64(2), type: Int64.ONE),
    );
    await settle(tester);
    expect(tester.widget<ReplyPage>(find.byType(ReplyPage)).items, isNull);
    controller.onDelete();
    await finish(tester);
  });

  testWidgets('评论上传前固定草稿，防重复并在成功后保留新草稿', (tester) async {
    var delivered = 0;
    await mount(
      tester,
      page(
        onSuccess: (reply) {
          delivered++;
          expect(reply, isNull);
          throw StateError('fixture callback');
        },
      ),
    );
    final editor = state(tester);
    draft(editor, '原草稿');
    editor.imageList.add(FilePicModel(path: image.path));
    late Future<void> pending;
    await tester.runAsync(() async {
      pending = editor.onPublish();
      await editor.onPublish();
      await interceptor.waitForRequests(1);
    });
    expect(requests.single.options.path, Api.uploadBfs);
    draft(editor, '新草稿');
    editor.imageList.clear();
    await tester.runAsync(() async {
      requests.first.reply.complete(uploaded());
      await interceptor.waitForRequests(2);
    });
    final body = requests.last.options.data as Map;
    expect(body['message'], '原草稿');
    expect(body['root'], 2);
    expect(body['parent'], 3);
    expect(jsonDecode(body['pictures']), hasLength(1));
    expect(requests.last.options.extra['account'], same(original));
    await tester.runAsync(() async {
      requests.last.reply.complete({'code': 0});
      await pending;
    });
    await settle(tester);
    expect(delivered, 1);
    expect(editor.editController.text, '新草稿');
    expect(editor.hasPub, isFalse);
    expect(find.text('发送成功，已保留新草稿'), findsOneWidget);
    expect(find.text('评论准备失败，请重试'), findsNothing);
    await finish(tester);
  });

  testWidgets('评论上传后切号不继续发送，待确认保留草稿且允许再次操作', (tester) async {
    var delivered = 0;
    await mount(tester, page(onSuccess: (_) => delivered++));
    final editor = state(tester);
    draft(editor, '草稿');
    editor.imageList.add(FilePicModel(path: image.path));
    late Future<void> uploading;
    await tester.runAsync(() async {
      uploading = editor.onPublish();
      await interceptor.waitForRequests(1);
    });
    Accounts.accountMode[AccountType.main.index] = replacement;
    await tester.runAsync(() async {
      requests.first.reply.complete(uploaded());
      await uploading;
    });
    await settle(tester);
    expect(requests, hasLength(1));
    editor.imageList.clear();
    final saving = editor.onPublish();
    await until(tester, () => requests.length == 2);
    requests.last.reply.complete({'code': '0'});
    await settle(tester);
    await saving;
    expect(delivered, 0);
    expect(editor.editController.text, '草稿');
    expect(find.text('操作结果待确认，请先核对后再操作'), findsOneWidget);
    final retry = editor.onPublish();
    await until(tester, () => requests.length == 3);
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await retry;
    expect(delivered, 1);
    expect(find.byType(ReplyPage), findsNothing);
    expect(find.text('发送成功，请刷新评论列表查看'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('评论关闭后的迟到成功不回调或关闭后来打开的页面', (tester) async {
    var delivered = 0;
    await mount(tester, page(onSuccess: (_) => delivered++));
    final editor = state(tester);
    draft(editor, '草稿');
    final saving = editor.onPublish();
    await until(tester, () => requests.length == 1);
    Get.back();
    await settle(tester);
    Get.to(() => const Scaffold(body: Text('新页面')));
    await settle(tester);
    requests.first.reply.complete({'code': 0});
    await settle(tester);
    await saving;
    expect(delivered, 0);
    expect(find.text('新页面'), findsOneWidget);
    expect(find.text('发送成功，请刷新评论列表查看'), findsNothing);
    await finish(tester);
  });

  ReplyInfo item() => ReplyInfo(
    id: Int64(2),
    oid: Int64.ONE,
    type: Int64.ONE,
  );

  testWidgets('删除评论防重复，失败保留弹窗，成功回调失败仍显示成功', (tester) async {
    final owner = await mount(tester);
    var deleted = 0;
    final dialog = showDeleteReplyDialog(
      owner,
      account: original,
      item: item(),
      isCurrent: () => owner.mounted,
      onDelete: () {
        deleted++;
        throw StateError('fixture callback');
      },
    );
    await settle(tester);
    final submit = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '确定'))
        .onPressed!;
    submit();
    submit();
    await until(tester, () => requests.length == 1);
    expect(find.text('删除中'), findsOneWidget);
    requests.first.reply.complete({'code': 12022, 'message': '暂时无法删除'});
    await settle(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(deleted, 0);
    await tester.tap(find.text('确定'));
    await until(tester, () => requests.length == 2);
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    await dialog;
    expect(deleted, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('删除成功'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('删除弹窗取消或切号后拒绝迟到结果，保留新页面', (tester) async {
    final owner = await mount(tester);
    var deleted = 0;
    final dialog = showDeleteReplyDialog(
      owner,
      account: original,
      item: item(),
      isCurrent: () => owner.mounted && identical(Accounts.main, original),
      onDelete: () => deleted++,
    );
    await settle(tester);
    await tester.tap(find.text('确定'));
    await until(tester, () => requests.length == 1);
    Accounts.accountMode[AccountType.main.index] = replacement;
    requests.first.reply.complete({'code': 0});
    await settle(tester);
    expect(deleted, 0);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settle(tester);
    await dialog;
    Accounts.accountMode[AccountType.main.index] = original;
    final second = showDeleteReplyDialog(
      owner,
      account: original,
      item: item(),
      isCurrent: () => owner.mounted,
      onDelete: () => deleted++,
    );
    await settle(tester);
    await tester.tap(find.text('确定'));
    await until(tester, () => requests.length == 2);
    await tester.tap(find.text('取消'));
    await settle(tester);
    await second;
    Get.to(() => const Scaffold(body: Text('新页面')));
    await settle(tester);
    requests.last.reply.complete({'code': 0});
    await settle(tester);
    expect(deleted, 0);
    expect(find.text('新页面'), findsOneWidget);
    expect(find.text('删除成功'), findsNothing);
    await finish(tester);
  });
}
