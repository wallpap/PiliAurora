import 'dart:math' as math;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:canvas_danmaku/special_danmaku_painter.dart';
import 'package:canvas_danmaku/utils/utils.dart' as canvas_danmaku;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:pili_aurora/pages/danmaku/prewarm_policy.dart';
import 'package:pili_aurora/pages/danmaku/raster_cache.dart';
import 'package:pili_aurora/pages/danmaku/render_guard.dart';
import 'package:pili_aurora/pages/danmaku/trajectory.dart';

class _PreparedEntry {
  _PreparedEntry(this.trajectory, this.track, this.scrolling);

  DanmakuTrajectory trajectory;
  final int track;
  final bool scrolling;
}

class WindowsDanmakuRenderer<T> extends ChangeNotifier {
  WindowsDanmakuRenderer({
    required DanmakuOption option,
    required this._size,
    double devicePixelRatio = 1,
    String? fontFamily,
    int rasterCacheMaxBytes = 16 * 1024 * 1024,
    int rasterCacheMaxEntries = 512,
  }) : _option = option,
       rasters = DanmakuRasterCache(
         option: option,
         devicePixelRatio: devicePixelRatio,
         fontFamily: fontFamily,
         maxBytes: rasterCacheMaxBytes,
         maxEntries: rasterCacheMaxEntries,
       ) {
    _layoutTracks();
    controller = DanmakuController<T>(
      addDanmaku: add,
      updateOption: updateOption,
      pause: pause,
      resume: resume,
      clear: clear,
      getOption: () => _option,
      isRunning: () => running,
      findDanmaku: (_) => const Iterable.empty(),
      findSingleDanmaku: (_) => null,
      getTrackCount: () => scrollDanmaku.length,
      scrollDanmaku: scrollDanmaku,
      staticDanmaku: staticDanmaku,
      specialDanmaku: specialDanmaku,
    );
  }

  /// 活动弹幕图片的账面内存预算。
  ///
  /// 高密度真实弹幕下，64 MiB 容易在短时间内触发大量拒绝。默认提升到
  /// 96 MiB；仍可使用 dart-define 针对设备或基准覆盖。
  static const maxActiveBytesMiB = int.fromEnvironment(
    'WINDOWS_DANMAKU_MAX_ACTIVE_BYTES_MIB',
    defaultValue: 96,
  );
  static const maxActiveBytes = maxActiveBytesMiB * 1024 * 1024;
  static const maxActiveItems = 600;
  static const maxPendingPrewarm = 64;
  // 候选尚未完成长测和尾延迟验证，只通过编译参数显式启用。
  static const adaptivePrewarm = bool.fromEnvironment(
    'WINDOWS_DANMAKU_ADAPTIVE_PREWARM',
    defaultValue: false,
  );
  static const layoutFirstPrewarm =
      adaptivePrewarm ||
      bool.fromEnvironment(
        'WINDOWS_DANMAKU_LAYOUT_FIRST_PREWARM',
        defaultValue: false,
      );
  static const prewarmEnabled = bool.fromEnvironment(
    'WINDOWS_DANMAKU_PREWARM',
    defaultValue: true,
  );

  late final DanmakuController<T> controller;
  final DanmakuRasterCache rasters;
  final scrollDanmaku = <List<DanmakuItem<T>>>[];
  final staticDanmaku = <DanmakuItem<T>?>[];
  final specialDanmaku = <DanmakuItem<T>>[];
  final _entries = <DanmakuItem<T>, _PreparedEntry>{};
  final _pending = <DanmakuRasterKey, DanmakuContentItem<T>>{};
  final _prewarmPolicy = adaptivePrewarm ? DanmakuPrewarmPolicy() : null;
  final _random = math.Random(0);
  final _paint = Paint();
  DanmakuOption _option;
  Size _size;
  double _trackHeight = 0;
  double _unsafeUntilMs = 0;
  bool _disposed = false;
  bool _prewarmScheduled = false;
  bool prewarmingAllowed = true;
  bool running = true;
  int _elapsedMicroseconds = 0;
  int get tick => _elapsedMicroseconds ~/ 1000;
  int activeBytes = 0;
  int directPaints = 0;
  int groupPaints = 0;
  int prewarmed = 0;
  int prewarmedLayouts = 0;
  int prewarmMicros = 0;
  int prewarmBackoffs = 0;
  int maxPrewarmImagesPerBatch = 0;
  int? observedFrameBudgetMicros;
  int rejectedByMemoryBudget = 0;
  int rejectedByActiveItemLimit = 0;
  int rejectedByTrack = 0;
  int rejectedByRaster = 0;

  bool get isEmpty => _entries.isEmpty && specialDanmaku.isEmpty;
  bool get canPaintDirectly => specialDanmaku.isEmpty && tick >= _unsafeUntilMs;

  Map<String, Object?> get statistics => {
    'renderer': 'windows-preprocess',
    'clockMode': 'frame-delta',
    'active': _entries.length + specialDanmaku.length,
    'activeImageBytes': activeBytes,
    'activeImageLimitBytes': maxActiveBytes,
    'activeItemLimit': maxActiveItems,
    'cacheEntries': rasters.length,
    'cacheEntryLimit': rasters.maxEntries,
    'cacheImageLimitBytes': rasters.maxBytes,
    'cacheImageBytes': rasters.bytes,
    'cacheHits': rasters.hits,
    'layouts': rasters.layouts,
    'rasterizations': rasters.rasterizations,
    'evictions': rasters.evictions,
    'evictionsByBytes': rasters.evictionsByBytes,
    'evictionsByEntries': rasters.evictionsByEntries,
    'evictedLayouts': rasters.evictedLayouts,
    'evictedImages': rasters.evictedImages,
    'evictedImageBytes': rasters.evictedImageBytes,
    'pendingPrewarm': _pending.length,
    'prewarmed': prewarmed,
    'prewarmStrategy': adaptivePrewarm
        ? 'adaptive'
        : layoutFirstPrewarm
        ? 'layout-first'
        : 'image-first',
    'recentAdmissionSamples': _prewarmPolicy?.samples ?? 0,
    'recentAccepted': _prewarmPolicy?.accepted ?? 0,
    'prewarmBackoffs': prewarmBackoffs,
    'maxPrewarmImagesPerBatch': maxPrewarmImagesPerBatch,
    'observedFrameBudgetMicros': observedFrameBudgetMicros,
    'prewarmedLayouts': prewarmedLayouts,
    'prewarmMicros': prewarmMicros,
    'directPaints': directPaints,
    'groupPaints': groupPaints,
    'overlapSafe': canPaintDirectly,
    'rejectedByMemoryBudget': rejectedByMemoryBudget,
    'rejectedByActiveItemLimit': rejectedByActiveItemLimit,
    'rejectedByTrack': rejectedByTrack,
    'rejectedByRaster': rejectedByRaster,
  };

  void _layoutTracks() {
    final painter = TextPainter(
      text: TextSpan(
        text: '弹幕',
        style: TextStyle(
          fontSize: _option.fontSize,
          height: _option.lineHeight,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    _trackHeight = painter.height;
    painter.dispose();
    final count = _size.isEmpty || _trackHeight <= 0
        ? 0
        : math.max(
            0,
            (_size.height * _option.area / _trackHeight).floor() -
                (_option.safeArea && _option.area == 1 ? 1 : 0),
          );
    if (scrollDanmaku.length < count) {
      scrollDanmaku.addAll(
        List.generate(count - scrollDanmaku.length, (_) => <DanmakuItem<T>>[]),
      );
    } else {
      scrollDanmaku.length = count;
    }
    staticDanmaku.length = count;
  }

  double _velocity(double width) =>
      (_size.width + (_option.scrollFixedVelocity ? 0 : width)) /
      _option.durationInMilliseconds;

  DanmakuTrajectory _trajectory(
    DanmakuItem<T> item,
    int track,
    bool scrolling, {
    double? startX,
    double? staticRemaining,
  }) {
    final velocity = scrolling ? _velocity(item.width) : 0.0;
    final x = scrolling
        ? startX ?? _size.width
        : (_size.width - item.width) / 2;
    return DanmakuTrajectory(
      startMs: tick.toDouble(),
      endMs:
          tick +
          (scrolling
              ? (x + item.width) / velocity
              : staticRemaining ?? _option.staticDurationInMilliseconds),
      startX: x,
      y: track * _trackHeight,
      width: item.width,
      height: item.height,
      velocity: velocity,
    );
  }

  void _recordOverlap(DanmakuTrajectory trajectory) {
    for (final entry in _entries.values) {
      if (trajectory.overlapsDuring(
        entry.trajectory,
        padding: 1 / rasters.devicePixelRatio,
      )) {
        _unsafeUntilMs = math.max(
          _unsafeUntilMs,
          math.min(trajectory.endMs, entry.trajectory.endMs),
        );
      }
    }
  }

  bool add(DanmakuContentItem<T> content) {
    final accepted = _add(content);
    if (adaptivePrewarm && content.type != DanmakuItemType.special) {
      _prewarmPolicy!.recordAdmission(accepted);
    }
    return accepted;
  }

  bool _add(DanmakuContentItem<T> content) {
    // 已到入场时刻的内容不再属于未来工作，即使本次准入被拒绝也应取消预热。
    if (layoutFirstPrewarm) {
      _pending.remove(DanmakuRasterCache.keyOf(content));
    }
    if (_disposed ||
        _option.hideWhat(content.type) ||
        scrollDanmaku.isEmpty ||
        _entries.length + specialDanmaku.length >= maxActiveItems ||
        _option.durationInMilliseconds <= 0 ||
        _option.staticDurationInMilliseconds <= 0) {
      if (_entries.length + specialDanmaku.length >= maxActiveItems) {
        rejectedByActiveItemLimit++;
      }
      return false;
    }
    if (content is SpecialDanmakuContentItem<T>) {
      if (!DanmakuRenderGuard.canRasterizeSpecial(
        content,
        rasters.devicePixelRatio,
        _option.strokeWidth,
        _option.fontWeight,
      )) {
        rejectedByRaster++;
        return false;
      }
      canvas_danmaku.DmUtils.devicePixelRatio = rasters.devicePixelRatio;
      canvas_danmaku.DmUtils.fontFamily = rasters.fontFamily;
      final image = canvas_danmaku.DmUtils.recordSpecialDanmakuImg(
        content: content,
        strokeWidth: _option.strokeWidth,
        fontWeight: _option.fontWeight,
      );
      final bytes = image.width * image.height * 4;
      if (activeBytes + bytes > maxActiveBytes) {
        image.dispose();
        rejectedByMemoryBudget++;
        return false;
      }
      specialDanmaku.add(
        DanmakuItem<T>(
          content: content,
          width: content.rect.width,
          height: content.rect.height,
          image: image,
          drawTick: tick,
        ),
      );
      activeBytes += bytes;
      notifyListeners();
      return true;
    }
    final raster = rasters.get(content);
    if (raster == null) {
      rejectedByRaster++;
      return false;
    }
    if (activeBytes + raster.bytes > maxActiveBytes) {
      rejectedByMemoryBudget++;
      return false;
    }
    var scrolling = content.type == DanmakuItemType.scroll;
    var track = -1;
    if (!scrolling) {
      for (var index = 0; index < staticDanmaku.length; index++) {
        final candidate = content.type == DanmakuItemType.bottom
            ? staticDanmaku.length - index - 1
            : index;
        if (staticDanmaku[candidate] == null) {
          track = candidate;
          break;
        }
      }
      if (_option.static2Scroll && (track < 0 || raster.width > _size.width)) {
        track = -1;
        scrolling = !_option.hideScroll;
      }
    }
    if (scrolling) {
      final velocity = _velocity(raster.width);
      for (var index = 0; index < scrollDanmaku.length; index++) {
        final previous = scrollDanmaku[index].lastOrNull;
        if (previous == null ||
            _entries[previous]!.trajectory.canBeFollowedBy(
              raster.width,
              velocity,
              _size.width,
              tick.toDouble(),
            )) {
          track = index;
          break;
        }
      }
      if (track < 0 && (content.selfSend || _option.massiveMode)) {
        track = content.selfSend ? 0 : _random.nextInt(scrollDanmaku.length);
      }
    }
    if (track < 0) {
      rejectedByTrack++;
      return false;
    }
    final image = rasters.rasterize(content, raster);
    if (image == null) return false;
    final item = DanmakuItem<T>(
      content: content,
      width: raster.width,
      height: raster.height,
      image: image.clone(),
      drawTick: tick,
    );
    final trajectory = _trajectory(item, track, scrolling);
    item.xPosition = trajectory.startX;
    _recordOverlap(trajectory);
    _entries[item] = _PreparedEntry(trajectory, track, scrolling);
    if (scrolling) {
      scrollDanmaku[track].add(item);
    } else {
      staticDanmaku[track] = item;
    }
    activeBytes += raster.bytes;
    notifyListeners();
    return true;
  }

  void queuePrewarm(Iterable<DanmakuContentItem<T>> contents) {
    if (_disposed || !prewarmEnabled || !running || !prewarmingAllowed) return;
    for (final content in contents) {
      if (content.type == DanmakuItemType.special ||
          _option.hideWhat(content.type)) {
        continue;
      }
      final prepareImages =
          adaptivePrewarm &&
          _prewarmPolicy!.allowImages(
            pending: _pending.length + 1,
            activeBytes: activeBytes,
            maxActiveBytes: maxActiveBytes,
            nowMs: tick,
          );
      if (layoutFirstPrewarm && !prepareImages
          ? rasters.isPrepared(content)
          : rasters.isRasterized(content)) {
        continue;
      }
      final key = DanmakuRasterCache.keyOf(content);
      if (_pending.length >= maxPendingPrewarm && !_pending.containsKey(key)) {
        break;
      }
      _pending[key] = content;
    }
    _schedulePrewarm();
  }

  void _schedulePrewarm() {
    if (_prewarmScheduled ||
        _pending.isEmpty ||
        _disposed ||
        !running ||
        !prewarmingAllowed) {
      return;
    }
    _prewarmScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _prewarmScheduled = false;
      if (_disposed || !running || !prewarmingAllowed) return;
      prewarmPending();
      _schedulePrewarm();
    }, debugLabel: 'danmaku-prewarm');
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void prewarmPending() {
    if (_disposed || !running || !prewarmingAllowed) return;
    final stopwatch = Stopwatch()..start();
    var count = 0;
    var images = 0;
    // 候选默认只预排版；自适应分支仅在低压力、高准入率下限量生成图片。
    // 单次排版不可中断，因此这是软预算；未完成项下帧继续，入场仍可同步兜底。
    while (_pending.isNotEmpty &&
        count < 4 &&
        stopwatch.elapsedMicroseconds < (layoutFirstPrewarm ? 500 : 2000)) {
      final content = _pending.remove(_pending.keys.first)!;
      if (layoutFirstPrewarm) {
        final before = rasters.layouts;
        final raster = rasters.get(content);
        prewarmedLayouts += rasters.layouts - before;
        if (adaptivePrewarm &&
            raster != null &&
            raster.image == null &&
            _entries.length + specialDanmaku.length < maxActiveItems &&
            activeBytes + raster.bytes <= maxActiveBytes &&
            // 图片预热不触发字节淘汰；布局仍受既有条目上限和 LRU 约束。
            rasters.bytes + raster.bytes <= rasters.maxBytes &&
            _prewarmPolicy!.allowImages(
              pending: _pending.length + 1,
              activeBytes: activeBytes,
              maxActiveBytes: maxActiveBytes,
              nowMs: tick,
            )) {
          final beforeImages = rasters.rasterizations;
          rasters.rasterize(content, raster);
          final prepared = rasters.rasterizations - beforeImages;
          prewarmed += prepared;
          images += prepared;
        }
      } else {
        final before = rasters.rasterizations;
        rasters.get(content, rasterize: true);
        final prepared = rasters.rasterizations - before;
        prewarmed += prepared;
        images += prepared;
      }
      count++;
      // 高置信度场景也不把多个图片任务塞进同一帧；剩余项下一帧继续。
      if (adaptivePrewarm && images > 0) break;
    }
    maxPrewarmImagesPerBatch = math.max(maxPrewarmImagesPerBatch, images);
    stopwatch.stop();
    prewarmMicros += stopwatch.elapsedMicroseconds;
  }

  void recordFrameCost(Duration cost, Duration budget) {
    if (!adaptivePrewarm || _disposed) return;
    observedFrameBudgetMicros = budget.inMicroseconds;
    if (cost <= budget) return;
    _prewarmPolicy!.backoff(tick);
    prewarmBackoffs++;
  }

  void advance(Duration elapsed) {
    if (_disposed || !running || elapsed <= Duration.zero) return;
    _elapsedMicroseconds += elapsed.inMicroseconds;
    final moving =
        scrollDanmaku.any((track) => track.isNotEmpty) ||
        specialDanmaku.isNotEmpty;
    final previousCount = _entries.length + specialDanmaku.length;
    _entries.removeWhere((item, entry) {
      if (tick >= entry.trajectory.endMs) {
        if (entry.scrolling) {
          if (entry.track < scrollDanmaku.length) {
            scrollDanmaku[entry.track].remove(item);
          }
        } else if (entry.track < staticDanmaku.length &&
            identical(staticDanmaku[entry.track], item)) {
          staticDanmaku[entry.track] = null;
        }
        _disposeItem(item);
        return true;
      }
      item.xPosition = entry.trajectory.xAt(tick.toDouble());
      return false;
    });
    specialDanmaku.removeWhere((item) {
      final content = item.content as SpecialDanmakuContentItem<T>;
      if (tick - item.drawTick! >= content.duration) {
        _disposeItem(item);
        return true;
      }
      return false;
    });
    if (moving || previousCount != _entries.length + specialDanmaku.length) {
      notifyListeners();
    }
  }

  void _disposeItem(DanmakuItem<T> item) {
    final image = item.image;
    if (image != null) activeBytes -= image.width * image.height * 4;
    item.dispose();
  }

  void _removeDisposed() {
    for (final track in scrollDanmaku) {
      track.removeWhere((item) => item.image == null);
    }
    for (var index = 0; index < staticDanmaku.length; index++) {
      if (staticDanmaku[index]?.image == null) staticDanmaku[index] = null;
    }
  }

  void updateOption(DanmakuOption option) => configure(option: option);

  void configure({
    DanmakuOption? option,
    Size? size,
    double? devicePixelRatio,
    String? fontFamily,
    bool useDefaultFontFamily = false,
  }) {
    final previousOption = _option;
    final previousSize = _size;
    final nextOption = option ?? _option;
    final nextSize = size ?? _size;
    final nextRatio = devicePixelRatio ?? rasters.devicePixelRatio;
    final nextFamily = useDefaultFontFamily
        ? null
        : fontFamily ?? rasters.fontFamily;
    if (_sameOption(nextOption, _option) &&
        nextSize == _size &&
        nextRatio == rasters.devicePixelRatio &&
        nextFamily == rasters.fontFamily) {
      return;
    }
    final rasterChanged =
        nextRatio != rasters.devicePixelRatio ||
        nextFamily != rasters.fontFamily ||
        nextOption.fontSize != _option.fontSize ||
        nextOption.fontWeight != _option.fontWeight ||
        nextOption.strokeWidth != _option.strokeWidth;
    _option = nextOption;
    _size = nextSize;
    rasters.option = nextOption;
    rasters.devicePixelRatio = nextRatio;
    rasters.fontFamily = nextFamily;
    _pending.clear();
    if (rasterChanged) rasters.clear();
    _layoutTracks();
    final retained = _entries.entries.toList();
    _entries.clear();
    _unsafeUntilMs = 0;
    for (final record in retained) {
      final item = record.key;
      final entry = record.value;
      final oldTrajectory = entry.trajectory;
      if (entry.track >= scrollDanmaku.length ||
          _option.hideWhat(item.content.type) ||
          (entry.scrolling && _option.hideScroll) ||
          _option.durationInMilliseconds <= 0 ||
          _option.staticDurationInMilliseconds <= 0) {
        _disposeItem(item);
        continue;
      }
      final progress =
          (previousSize.width - item.xPosition) /
          (previousSize.width + item.width);
      if (rasterChanged) {
        final raster = rasters.get(item.content, rasterize: true);
        _disposeItem(item);
        if (raster == null || activeBytes + raster.bytes > maxActiveBytes) {
          continue;
        }
        item
          ..image = raster.image!.clone()
          ..width = raster.width
          ..height = raster.height;
        activeBytes += raster.bytes;
      }
      entry.trajectory = _trajectory(
        item,
        entry.track,
        entry.scrolling,
        startX: _size.width - progress * (_size.width + item.width),
        staticRemaining: math.max(
          0,
          (oldTrajectory.endMs - tick) /
              previousOption.staticDurationInMilliseconds *
              _option.staticDurationInMilliseconds,
        ),
      );
      item.xPosition = entry.trajectory.startX;
      _recordOverlap(entry.trajectory);
      _entries[item] = entry;
    }
    _removeDisposed();
    specialDanmaku.removeWhere((item) {
      if (_option.hideSpecial) {
        _disposeItem(item);
        return true;
      }
      if (rasterChanged) {
        final content = item.content as SpecialDanmakuContentItem<T>;
        _disposeItem(item);
        if (!DanmakuRenderGuard.canRasterizeSpecial(
          content,
          rasters.devicePixelRatio,
          _option.strokeWidth,
          _option.fontWeight,
        )) {
          return true;
        }
        canvas_danmaku.DmUtils.devicePixelRatio = rasters.devicePixelRatio;
        canvas_danmaku.DmUtils.fontFamily = rasters.fontFamily;
        final image = canvas_danmaku.DmUtils.recordSpecialDanmakuImg(
          content: content,
          fontWeight: _option.fontWeight,
          strokeWidth: _option.strokeWidth,
        );
        final bytes = image.width * image.height * 4;
        if (activeBytes + bytes > maxActiveBytes) {
          image.dispose();
          return true;
        }
        item.image = image;
        activeBytes += bytes;
      }
      return false;
    });
    notifyListeners();
  }

  bool _sameOption(DanmakuOption first, DanmakuOption second) =>
      first.fontSize == second.fontSize &&
      first.fontWeight == second.fontWeight &&
      first.strokeWidth == second.strokeWidth &&
      first.lineHeight == second.lineHeight &&
      first.area == second.area &&
      first.safeArea == second.safeArea &&
      first.duration == second.duration &&
      first.staticDuration == second.staticDuration &&
      first.scrollFixedVelocity == second.scrollFixedVelocity &&
      first.massiveMode == second.massiveMode &&
      first.static2Scroll == second.static2Scroll &&
      first.hideScroll == second.hideScroll &&
      first.hideTop == second.hideTop &&
      first.hideBottom == second.hideBottom &&
      first.hideSpecial == second.hideSpecial;

  void paint(Canvas canvas, Size size, {double opacity = 1}) {
    if (_disposed || opacity <= 0 || isEmpty) return;
    final group = opacity < 1 && !canPaintDirectly;
    canvas
      ..save()
      ..clipRect(Offset.zero & size);
    if (group) {
      canvas.saveLayer(
        Offset.zero & size,
        Paint()..color = Color.fromRGBO(255, 255, 255, opacity),
      );
      groupPaints++;
    } else {
      directPaints++;
    }
    _paint.color = Color.fromRGBO(255, 255, 255, group ? 1 : opacity);
    for (var track = 0; track < scrollDanmaku.length; track++) {
      for (final item in scrollDanmaku[track]) {
        _paintItem(canvas, item, track * _trackHeight);
      }
    }
    for (var track = 0; track < staticDanmaku.length; track++) {
      final item = staticDanmaku[track];
      if (item != null) _paintItem(canvas, item, track * _trackHeight);
    }
    if (specialDanmaku.isNotEmpty) {
      canvas_danmaku.DmUtils.devicePixelRatio = rasters.devicePixelRatio;
      canvas_danmaku.DmUtils.fontFamily = rasters.fontFamily;
      SpecialDanmakuPainter(
        length: specialDanmaku.length,
        danmakuItems: specialDanmaku,
        fontSize: _option.fontSize,
        fontWeight: _option.fontWeight,
        strokeWidth: _option.strokeWidth,
        running: running,
        tick: tick,
      ).paint(canvas, size);
    }
    if (group) canvas.restore();
    canvas.restore();
  }

  void _paintItem(Canvas canvas, DanmakuItem<T> item, double y) {
    final image = item.image!;
    if (image.width == item.width.ceil()) {
      canvas.drawImage(image, Offset(item.xPosition, y), _paint);
    } else {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(item.xPosition, y, item.width, item.height),
        _paint,
      );
    }
  }

  void pause() {
    running = false;
    notifyListeners();
  }

  void resume() {
    running = true;
    _schedulePrewarm();
    notifyListeners();
  }

  void clear() {
    for (final item in _entries.keys) {
      _disposeItem(item);
    }
    for (final item in specialDanmaku) {
      _disposeItem(item);
    }
    _entries.clear();
    specialDanmaku.clear();
    _removeDisposed();
    _pending.clear();
    _prewarmPolicy?.clear();
    _unsafeUntilMs = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    clear();
    _disposed = true;
    rasters.clear();
    super.dispose();
  }
}
