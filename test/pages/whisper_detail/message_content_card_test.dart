import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/pages/whisper_detail/widget/chat_item.dart';
import 'package:pili_aurora/pages/whisper_detail/widget/message_content_card.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/memory_box.dart';

void main() {
  setUpAll(() => GStorage.setting = MemoryBox<dynamic>());

  testWidgets('两类消息接入统一卡片，保留长按、右键和视频附言', (tester) async {
    for (final kind in [
      MessageContentKind.articleCard,
      MessageContentKind.videoCard,
    ]) {
      var longPresses = 0;
      var secondaryTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatItem(
              item: Message(
                id: 'card',
                messageKey: 1,
                sequence: 1,
                senderId: 1,
                timestamp: 1793016000,
                type: kind == MessageContentKind.articleCard ? 12 : 11,
                source: 0,
                content: StructuredMessageContent(kind, const {
                  'title': '消息标题',
                  'summary': '专栏摘要',
                  'image_urls': <String>[],
                  'times': 0,
                  'attach_msg': {'content': '视频附言'},
                }),
              ),
              eInfos: null,
              isOwner: true,
              onLongPress: () => longPresses++,
              onSecondaryTapUp: (_) => secondaryTaps++,
            ),
          ),
        ),
      );
      expect(find.byType(MessageContentCard), findsOneWidget);
      final title = kind == MessageContentKind.articleCard ? '消息标题' : '内容已失效';
      expect(find.text(title), findsOneWidget);
      if (kind == MessageContentKind.videoCard) {
        expect(find.text('视频附言', findRichText: true), findsOneWidget);
      }
      await tester.longPress(find.text(title));
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(title)),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      expect(longPresses, 1, reason: kind.name);
      expect(secondaryTaps, 1, reason: kind.name);
      expect(tester.takeException(), isNull);
    }
  });
}
