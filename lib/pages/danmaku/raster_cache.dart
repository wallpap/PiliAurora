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
  }) : assert(maxEntries > 0),
       assert(maxBytes > 0),
       assert(maxItemBytes > 0);

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
  int evictionsByBytes = 0;
  int evictionsByEntries = 0;

  int get length => _entries.length;

  bool isRasterized(DanmakuContentItem content) =>
      _entries[keyOf(content)]?.image != null;

  static DanmakuRasterKey keyOf(DanmakuContentItem content) => (
    content.text,
    content.color.toARGB32(),
    content.isColorful,
    content.selfSend,
    content.count,
  );

  ui.Image? rasterize(DanmakuContentItem content, DanmakuRaster entry) {
    if (entry.image == null) {
      final paragraph = entry.paragraph;
      if (paragraph == null) return null;
      canvas_danmaku.DmUtils.devicePixelRatio = devicePixelRatio;
      canvas_danmaku.DmUtils.fontFamily = fontFamily;
      canvas_danmaku.DmUtils.updateSelfSendPaint(option.strokeWidth);
      entry.image = canvas_danmaku.DmUtils.recordDanmakuImage(
        contentParagraph: paragraph,
        content: content,
        fontSize: option.fontSize,
        fontWeight: option.fontWeight,
        strokeWidth: option.strokeWidth,
      );
      paragraph.dispose();
      entry.paragraph = null;
      bytes += entry.bytes;
      rasterizations++;
    }
    _trim();
    return entry.image;
  }

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
    if (rasterize) {
      this.rasterize(content, entry);
    } else {
      _trim();
    }
    return entry;
  }

  void _trim() {
    while (_entries.length > maxEntries || bytes > maxBytes) {
      // 两个条件同时超限时分别记录，原因计数不要求互斥。
      if (bytes > maxBytes) evictionsByBytes++;
      if (_entries.length > maxEntries) evictionsByEntries++;
      final oldest = _entries.remove(_entries.keys.first)!;
      if (oldest.image != null) bytes -= oldest.bytes;
      oldest.dispose();
      evictions++;
    }
  }

  void clear() {
    for (final entry in _entries.values) {
      entry.dispose();
    }
    _entries.clear();
    bytes = 0;
  }
}
