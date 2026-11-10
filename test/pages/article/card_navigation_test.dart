import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';
import 'package:pili_aurora/models/remote/article/article_view/ops.dart';
import 'package:pili_aurora/pages/article/widgets/article_ops.dart';
import 'package:pili_aurora/pages/whisper_detail/widget/chat_item.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/memory_box.dart';

void main() {
  setUpAll(() => GStorage.setting = MemoryBox<dynamic>());
  Future<void> mount(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      builder: FlutterSmartDialog.init(),
      home: ImageLoadingScope(enabled: false, child: Scaffold(body: child)),
    ),
  );
  for (final clazz in ['article-card card', 'vote-card card']) {
    for (final id in ['', 'x', 'cv', '-1', 'invalid']) {
      testWidgets('$clazz 点击损坏 ID：$id', (tester) async {
        await mount(
          tester,
          CustomScrollView(
            slivers: [
              ArticleOpus(
                ops: [
                  ArticleOps(
                    attributes: Attributes(clazz: clazz),
                    insert: Insert(
                      card: InsertCard(
                        id: id,
                        url: 'https://example.invalid/card.png',
                        width: 200,
                        height: 100,
                      ),
                    ),
                  ),
                ],
                maxWidth: 200,
              ),
            ],
          ),
        );
        tester
            .widget<GestureDetector>(
              find
                  .ancestor(
                    of: find.byType(CachedImage),
                    matching: find.byType(GestureDetector),
                  )
                  .last,
            )
            .onTap!();
        await tester.pump();
        expect(
          find.text(clazz == 'article-card card' ? '专栏卡片信息无效' : '投票卡片信息无效'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        SmartDialog.dismiss(status: SmartStatus.allToast);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
      });
    }
  }
  for (final id in <Object?>[null, 'invalid', '-1', 0, -2, 1.5]) {
    testWidgets('私信直播卡片拒绝无效房间号：$id', (tester) async {
      await mount(
        tester,
        ChatItem(
          item: Message(
            id: 'fixture',
            messageKey: 1,
            sequence: 1,
            senderId: 2,
            timestamp: 0,
            type: 14,
            source: 0,
            content: StructuredMessageContent(
              MessageContentKind.commonShareCard,
              {
                'source': '直播',
                'sourceID': id,
                'title': '直播卡片',
              },
            ),
          ),
          eInfos: null,
          onLongPress: () {},
          onSecondaryTapUp: null,
          isOwner: true,
        ),
      );
      await tester.tap(find.text('直播卡片'));
      await tester.pump();
      expect(find.text('直播卡片信息无效'), findsOneWidget);
      expect(tester.takeException(), isNull);
      SmartDialog.dismiss(status: SmartStatus.allToast);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });
  }
}
