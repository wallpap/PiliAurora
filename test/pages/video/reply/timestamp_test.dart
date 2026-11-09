import 'package:flutter/gestures.dart';
import 'package:pili_aurora/common/widgets/text_more/text_more.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo, Content, Member;
import 'package:pili_aurora/pages/video/reply/widgets/reply_item_grpc.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../../support/memory_box.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.video = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
    await Diagnostics.instance.configure(
      level: DiagnosticLogLevel.warning,
    );
  });
  tearDownAll(Diagnostics.instance.dispose);

  testWidgets('动态评论的时间戳不查找不存在的视频控制器', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReplyItemGrpc(
            replyItem: ReplyInfo(
              content: Content(message: '时间是 03:12'),
              member: Member(name: '测试用户'),
            ),
            replyLevel: 0,
            getTag: () => 'dynamic-comment',
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      Diagnostics.instance.recentLogs.where(
        (record) => record['message'].toString().contains('failed to validate'),
      ),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('视频时间戳使用匹配 tag，超范围和关闭后不跳转', (tester) async {
    final player = _Player();
    final controller = _Detail(player, 200000);
    Get.put<VideoDetailController>(controller, tag: 'video-tag');
    addTearDown(
      () => Get.delete<VideoDetailController>(tag: 'video-tag', force: true),
    );

    Future<TextSpan> render(String message) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: FlutterSmartDialog.init(),
          home: Scaffold(
            body: ReplyItemGrpc(
              replyItem: ReplyInfo(
                content: Content(message: message),
                member: Member(name: '测试'),
              ),
              replyLevel: 0,
              getTag: () => 'video-tag',
            ),
          ),
        ),
      );
      TextSpan? found;
      for (final rich in tester.widgetList<TextMore>(find.byType(TextMore))) {
        void visit(InlineSpan span) {
          if (span is TextSpan) {
            if (span.text?.contains(message) == true) found = span;
            for (final child in span.children ?? <InlineSpan>[]) {
              visit(child);
            }
          }
        }

        if (rich.textSpan != null) visit(rich.textSpan!);
      }
      expect(found, isNotNull);
      return found!;
    }

    final valid = await render('03:12');
    expect(valid.recognizer, isA<TapGestureRecognizer>());
    (valid.recognizer! as TapGestureRecognizer).onTap!();
    expect(player.seeks, [const Duration(seconds: 192)]);
    final huge = await render('999999999999999999999999:00');
    expect(huge.recognizer, isNull);
    expect(tester.takeException(), isNull);
    controller.data = PlayUrlModel(timeLength: 1000);
    expect((await render('03:12')).recognizer, isNull);
    controller.data = PlayUrlModel();
    expect((await render('03:12')).recognizer, isNull);
    controller.data = PlayUrlModel(timeLength: 200000);
    final beforeClose = await render('03:12');
    Get.delete<VideoDetailController>(tag: 'video-tag', force: true);
    (beforeClose.recognizer! as TapGestureRecognizer).onTap!();
    expect(player.seeks, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  });
}

class _Player extends GetxController implements PlPlayerController {
  final seeks = <Duration>[];
  @override
  Future<void> seekTo(Duration position, {bool isSeek = true}) async =>
      seeks.add(position);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Detail extends GetxController implements VideoDetailController {
  _Detail(this.plPlayerController, int? duration)
    : data = PlayUrlModel(timeLength: duration);
  @override
  PlayUrlModel data;
  @override
  final PlPlayerController plPlayerController;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
