import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/pages/whisper_detail/widget/chat_item.dart';
import 'package:pili_aurora/pages/whisper_detail/widget/message_content_card.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/utils/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    GStorage.setting = await Hive.openBox<dynamic>(
      'message_content_card_test',
      bytes: Uint8List(0),
    );
  });
  tearDownAll(Hive.close);

  testWidgets('多图在窄屏和宽屏保持封面比例，放大文字后不溢出', (tester) async {
    for (final width in [332.0, 452.0]) {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
                child: Center(
                  child: SizedBox(
                    width: width,
                    child: MessageContentCard(
                      coverUrls: const ['', '', '', ''],
                      title: '长标题' * 30,
                      summary: '长摘要' * 50,
                      onTap: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final coverSize = tester.getSize(find.byType(AspectRatio));
        final expectedWidth = width < 400 ? width : 400.0;
        expect(coverSize.width, expectedWidth);
        expect(coverSize.height, closeTo(expectedWidth * 9 / 16, 0.001));
        expect(find.byType(NetworkImgLayer), findsNWidgets(3));
        expect(find.text('共 4 张'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('无封面时省略图片区，整张卡片可点击', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageContentCard(
            coverUrls: const [],
            title: '无封面专栏',
            summary: '专栏摘要',
            onTap: () => taps++,
          ),
        ),
      ),
    );
    expect(find.byType(AspectRatio), findsNothing);
    await tester.tap(find.text('专栏摘要'));
    expect(taps, 1);
  });

  testWidgets('两类消息接入统一卡片，保留长按、右键和视频附言', (tester) async {
    var longPresses = 0;
    var secondaryTaps = 0;
    for (final kind in [
      MessageContentKind.articleCard,
      MessageContentKind.videoCard,
    ]) {
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
      expect(tester.takeException(), isNull);
    }
    expect(longPresses, 2);
    expect(secondaryTaps, 2);
  });
}
