import 'dart:ui' as ui;

import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:canvas_danmaku/utils/utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('danmaku raster replaces emote text with its inline image', () async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xFFFF0000), BlendMode.src);
    final source = recorder.endRecording().toImageSync(8, 12);
    final content = DanmakuContentItem(
      'hello [emote]',
      inlineImages: [
        DanmakuInlineImage(
          placeholder: '[emote]',
          image: source,
          width: 8,
          height: 12,
        ),
      ],
    );
    final paragraph = DmUtils.generateParagraph(
      content: content,
      fontSize: 24,
      fontWeight: FontWeight.values.indexOf(FontWeight.normal),
    );
    final raster = DmUtils.recordDanmakuImage(
      contentParagraph: paragraph,
      content: content,
      fontSize: 24,
      fontWeight: FontWeight.values.indexOf(FontWeight.normal),
      strokeWidth: 2,
    );
    final emoteBox = paragraph.getBoxesForPlaceholders().single.toRect();
    final pixels = (await raster.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    final x = (emoteBox.center.dx + 1).floor();
    final y = (emoteBox.center.dy + 1).floor();
    final pixel = (y * raster.width + x) * 4;

    expect(emoteBox.width, 8);
    expect(pixels.getUint8(pixel), greaterThan(200));
    expect(pixels.getUint8(pixel + 1), lessThan(50));
    expect(pixels.getUint8(pixel + 2), lessThan(50));

    paragraph.dispose();
    raster.dispose();
    content.dispose();
  });
}
