import 'dart:ui' as ui;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:canvas_danmaku/utils/utils.dart' as canvas_danmaku;

typedef DanmakuRasterKey = (String, int, bool, bool, int?);

class DanmakuRaster {
  DanmakuRaster(this.width, this.height, this.bytes, this.paragraph);

  final double width;
  final double height;
  final int bytes;
  ui.Paragraph? paragraph;
  ui.Image? image;

  void dispose() {
    paragraph?.dispose();
    image?.dispose();
    paragraph = null;
    image = null;
  }
}

class DanmakuRasterCache {
  DanmakuRasterCache({
    required this.option,
    required this.devicePixelRatio,
    this.fontFamily,
    this.maxEntries = 512,
    this.maxBytes = 16 * 1024 * 1024,
    this.maxItemBytes = 2 * 1024 * 1024,
  });

  DanmakuOption option;
  double devicePixelRatio;
  String? fontFamily;
  final int maxEntries;
  final int maxBytes;
  final int maxItemBytes;
  final _entries = <DanmakuRasterKey, DanmakuRaster>{};
  int bytes = 0;
  int hits = 0;
  int layouts = 0;
  int rasterizations = 0;
  int evictions = 0;

  int get length => _entries.length;

  static DanmakuRasterKey keyOf(DanmakuContentItem content) => (
    content.text,
    content.color.toARGB32(),
    content.isColorful,
    content.selfSend,
    content.count,
  );

  DanmakuRaster? get(DanmakuContentItem content, {bool rasterize = false}) {
    canvas_danmaku.DmUtils.devicePixelRatio = devicePixelRatio;
    canvas_danmaku.DmUtils.fontFamily = fontFamily;
    canvas_danmaku.DmUtils.updateSelfSendPaint(option.strokeWidth);
    final key = keyOf(content);
    var entry = _entries.remove(key);
    if (entry == null) {
      final paragraph = canvas_danmaku.DmUtils.generateParagraph(
        content: content,
        fontSize: option.fontSize,
        fontWeight: option.fontWeight,
      );
      layouts++;
      final width =
          paragraph.maxIntrinsicWidth +
          option.strokeWidth +
          (content.selfSend ? 4 : 0);
      final height = paragraph.height + option.strokeWidth;
      final pixelWidth = width * devicePixelRatio;
      final pixelHeight = height * devicePixelRatio;
      if (!pixelWidth.isFinite ||
          !pixelHeight.isFinite ||
          pixelWidth <= 0 ||
          pixelHeight <= 0 ||
          pixelWidth > 4096 ||
          pixelHeight > 4096) {
        paragraph.dispose();
        return null;
      }
      final imageBytes = pixelWidth.ceil() * pixelHeight.ceil() * 4;
      if (imageBytes > maxItemBytes || imageBytes > maxBytes) {
        paragraph.dispose();
        return null;
      }
      entry = DanmakuRaster(width, height, imageBytes, paragraph);
    } else {
      hits++;
    }
    _entries[key] = entry;
    if (rasterize && entry.image == null) {
      entry.image = canvas_danmaku.DmUtils.recordDanmakuImage(
        contentParagraph: entry.paragraph!,
        content: content,
        fontSize: option.fontSize,
        fontWeight: option.fontWeight,
        strokeWidth: option.strokeWidth,
      );
      entry.paragraph!.dispose();
      entry.paragraph = null;
      bytes += entry.bytes;
      rasterizations++;
    }
    while (_entries.length > maxEntries || bytes > maxBytes) {
      final oldest = _entries.remove(_entries.keys.first)!;
      if (oldest.image != null) bytes -= oldest.bytes;
      oldest.dispose();
      evictions++;
    }
    return entry;
  }

  void clear() {
    for (final entry in _entries.values) {
      entry.dispose();
    }
    _entries.clear();
    bytes = 0;
  }
}
