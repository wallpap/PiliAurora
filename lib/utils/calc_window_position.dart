import 'dart:math' as math;

import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:flutter/rendering.dart' show Offset, Size, Rect;
import 'package:screen_retriever/screen_retriever.dart';

/// 窗口恢复属于可选平台能力，失败时返回默认起点。
Future<Offset> calcWindowPosition(Size windowSize) async {
  var displays = <Display>[];
  Offset? cursor;
  try {
    displays = await screenRetriever.getAllDisplays();
  } catch (error, stackTrace) {
    logger.w('读取显示器列表失败', error: error.runtimeType, stackTrace: stackTrace);
  }
  try {
    cursor = await screenRetriever.getCursorScreenPoint();
  } catch (error, stackTrace) {
    logger.w('读取光标位置失败', error: error.runtimeType, stackTrace: stackTrace);
  }
  final bounds = displays.map(_visibleBounds).whereType<Rect>().toList();
  final saved = Pref.windowPosition;
  if (saved != null) {
    final position = Offset(saved[0], saved[1]);
    for (final area in bounds) {
      if (_canRestore(area, position)) return position;
    }
  }
  Rect? selected;
  if (cursor != null && cursor.dx.isFinite && cursor.dy.isFinite) {
    for (final area in bounds) {
      if (area.contains(cursor)) {
        selected = area;
        break;
      }
    }
  }
  if (selected == null) {
    try {
      selected = _visibleBounds(await screenRetriever.getPrimaryDisplay());
    } catch (error, stackTrace) {
      logger.w('读取主显示器失败', error: error.runtimeType, stackTrace: stackTrace);
    }
  }
  selected ??= bounds.firstOrNull;
  if (selected == null) return Offset.zero;
  if (saved != null && _canRestore(selected, Offset(saved[0], saved[1]))) {
    return Offset(saved[0], saved[1]);
  }
  final width = windowSize.width.isFinite && windowSize.width > 0
      ? windowSize.width
      : 1180.0;
  final height = windowSize.height.isFinite && windowSize.height > 0
      ? windowSize.height
      : 720.0;
  return Offset(
    selected.left + math.max(0, (selected.width - width) / 2),
    selected.top + math.max(0, (selected.height - height) / 2),
  );
}

bool _canRestore(Rect bounds, Offset position) =>
    position.dx >= bounds.left &&
    position.dy >= bounds.top &&
    position.dx < bounds.right - 30 &&
    position.dy < bounds.bottom - 30;

Rect? _visibleBounds(Display display) {
  bool validSize(Size size) =>
      size.width.isFinite &&
      size.height.isFinite &&
      size.width > 0 &&
      size.height > 0;
  final visible = display.visibleSize;
  final size = visible != null && validSize(visible) ? visible : display.size;
  if (!validSize(size)) return null;
  final origin = display.visiblePosition ?? Offset.zero;
  if (!origin.dx.isFinite || !origin.dy.isFinite) return null;
  return origin & size;
}
