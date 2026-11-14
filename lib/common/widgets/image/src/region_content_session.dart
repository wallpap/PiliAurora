import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';
import 'package:pili_aurora/common/widgets/image/image_resources.dart';
import 'package:pili_aurora/common/widgets/image/src/content_demand.dart';
import 'package:pili_aurora/common/widgets/image/src/image_source_store.dart';

abstract interface class RegionImageBackend {
  Future<RegionImageDecoder> open(ImageSourceLease source);
}

// 预先准备的后端在 open 尚未执行时也持有资源，由会话负责归还。
abstract interface class OwnedRegionImageBackend implements RegionImageBackend {
  Future<void> close();
}

abstract interface class RegionImageDecoder {
  Size get sourceSize;
  int get frameCount;
  bool get hasBoundedBase;
  bool get hasIndependentRegions;
  Future<RegionImage> decodeBase(int maximumPixels);
  Future<RegionImage> decodeRegion(RegionRequest request);
  void dispose();
}

@immutable
class RegionRequest {
  const RegionRequest({
    required this.level,
    required this.core,
    required this.read,
  });
  final int level;
  final Rect core;
  final Rect read;
  int get maximumBytes =>
      (read.width / math.pow(2, level)).ceil() *
      (read.height / math.pow(2, level)).ceil() *
      4;
}

abstract interface class DrainingRegionImageDecoder
    implements RegionImageDecoder {
  Future<void> get drained;
}

class RegionImage {
  const RegionImage({
    required this.image,
    required this.sourceRect,
    required this.core,
  });
  final ui.Image image;
  final Rect sourceRect;
  final Rect core;
  int get bytes => image.width * image.height * 4;
  void dispose() => image.dispose();
}

@immutable
class RegionContentState {
  const RegionContentState({
    this.sourceSize,
    this.version,
    this.images = const [],
    this.error,
    this.loading = true,
  });
  final Size? sourceSize;
  final Object? version;
  final List<RegionImage> images;
  final Object? error;
  final bool loading;
}

abstract interface class ContentSession
    implements ValueListenable<RegionContentState> {
  void update(ContentDemand demand);
  void dispose();
  Future<void> get drained;
}

class RegionContentSession extends ChangeNotifier implements ContentSession {
  RegionContentSession({
    required this._source,
    required this._backend,
    ImageResources? resources,
    this.maximumBytes = 16 << 20,
    this.maximumBaseBytes = 4 << 20,
    this.tileSize = 512,
    this.coalesceViewport = false,
  }) : _resources = resources ?? ImageResources.shared {
    if (maximumBaseBytes < 4 ||
        maximumBytes < maximumBaseBytes ||
        tileSize < 1) {
      throw ArgumentError('区域工作集必须容纳有界基础层');
    }
    _resources.addMemoryListener(_schedule);
  }

  final ImageSourceLease _source;
  final RegionImageBackend _backend;
  final ImageResources _resources;
  final int maximumBytes;
  final int maximumBaseBytes;
  final int tileSize;
  final bool coalesceViewport;
  ContentViewport? get viewport => _demand?.viewport;
  final _details = <(int, int, int), RegionImage>{};
  final _allocations = <RegionImage, ImageMemoryReservation>{};
  final _retired = <RegionImage>{};
  final _drained = Completer<void>();
  RegionContentState _value = const RegionContentState();
  RegionImageDecoder? _decoder;
  RegionImage? _base;
  ContentDemand? _demand;
  ImageWork<Object>? _work;
  Future<void>? _operation;
  int _reservedBytes = 0;
  bool _scheduled = false;
  bool _again = false;
  bool _retirementScheduled = false;
  int _surfaces = 0;
  Completer<void>? _retirement;
  bool _opening = false;
  bool _disposed = false;
  bool _failed = false;
  int _generation = 0;
  (int, int, int)? _activeKey;

  @override
  RegionContentState get value => _value;
  @override
  Future<void> get drained => _drained.future;
  int get workingSetBytes =>
      _reservedBytes +
      _allocations.values.fold(0, (sum, allocation) => sum + allocation.bytes);

  @override
  void update(ContentDemand demand) {
    if (_disposed) return;
    _demand = demand;
    _failed = false;
    _generation++;
    if (!demand.load ||
        demand.viewport.sourceRect.isEmpty ||
        (_activeKey != null &&
            !_requests(demand.viewport).containsKey(_activeKey))) {
      _work?.cancel();
    }
    _schedule();
  }

  void _schedule() {
    if (_scheduled || _disposed || _failed) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (_operation != null) {
        _again = true;
        return;
      }
      if (!_disposed && !_failed && _operation == null) {
        final generation = _generation;
        _operation = _service().then((more) {
          _operation = null;
          final again = _again;
          _again = false;
          if (!_disposed &&
              !_failed &&
              (more || again || generation != _generation)) {
            _schedule();
          }
        });
      }
    });
  }

  Future<bool> _service() async {
    final demand = _demand;
    if (demand == null || !demand.load || demand.viewport.sourceRect.isEmpty) {
      _discardDetails();
      return false;
    }
    if (!demand.viewport.physicalScale.isFinite ||
        demand.viewport.physicalScale <= 0) {
      return false;
    }
    if (_decoder == null) {
      if (_opening) return false;
      _opening = true;
      try {
        final decoder = await _run<RegionImageDecoder>(
          () => _backend.open(_source),
          (decoder) => decoder.dispose(),
          preprocessing: true,
        );
        if (decoder == null) return false;
        if (decoder.frameCount != 1 ||
            !decoder.hasBoundedBase ||
            !decoder.hasIndependentRegions ||
            decoder.sourceSize.isEmpty ||
            !decoder.sourceSize.width.isFinite ||
            !decoder.sourceSize.height.isFinite) {
          decoder.dispose();
          throw UnsupportedError('此来源没有已验证的有界静态区域能力');
        }
        _decoder = decoder;
        _publish();
      } catch (error) {
        _fail(error);
      } finally {
        _opening = false;
      }
      return !_failed;
    }
    if (_base == null) {
      // 当前尺度下可容纳完整基础层时，一次解码即可提供足够采样。
      // 已放大的超大来源仍保留小基础层，再单独请求可见区域。
      final level = math.max(
        0,
        (math.log(1 / math.min(1.0, demand.viewport.physicalScale)) / math.ln2)
            .floor(),
      );
      final factor = math.pow(2, level);
      final desiredBytes =
          (_decoder!.sourceSize.width / factor).ceil() *
          (_decoder!.sourceSize.height / factor).ceil() *
          4;
      final baseBytes = desiredBytes <= maximumBaseBytes
          ? desiredBytes
          : math.min(maximumBaseBytes, 4 << 20);
      final allocation = _resources.reserveRegionBytes(baseBytes);
      if (allocation == null) return false;
      _reservedBytes = baseBytes;
      try {
        final base = await _run<RegionImage>(
          () => _decoder!.decodeBase(baseBytes ~/ 4),
          (image) => image.dispose(),
        );
        _reservedBytes = 0;
        if (base == null) {
          allocation.dispose();
          return false;
        }
        if (base.bytes > baseBytes ||
            base.core != (Offset.zero & _decoder!.sourceSize) ||
            base.sourceRect != base.core) {
          base.dispose();
          throw StateError('区域后端返回的基础层超出约定');
        }
        allocation.shrinkTo(base.bytes);
        _allocations[base] = allocation;
        _base = base;
        _publish();
      } catch (error) {
        _reservedBytes = 0;
        allocation.dispose();
        _fail(error);
      }
      return !_failed;
    }
    final requiredScale = math.min(1.0, demand.viewport.physicalScale);
    if (_base!.image.width / _base!.sourceRect.width >= requiredScale &&
        _base!.image.height / _base!.sourceRect.height >= requiredScale) {
      if (_details.isNotEmpty) _discardDetails();
      return false;
    }
    final desired = _requests(demand.viewport);
    if (coalesceViewport &&
        desired.values.any(
          (request) =>
              request.maximumBytes > (40 << 20) ||
              request.maximumBytes + _base!.bytes > maximumBytes,
        )) {
      _fail(UnsupportedError('当前视口超过已验证的单区域容量，需要原路径接管'));
      return false;
    }
    final visible = demand.viewport.sourceRect;
    final retired = <RegionImage>[];
    for (final key in _details.keys.toList()) {
      if (!_details[key]!.core.overlaps(visible)) {
        retired.add(_details.remove(key)!);
      }
    }
    if (retired.isNotEmpty) {
      _publish();
      for (final image in retired) {
        _retire(image);
      }
    }
    for (final entry in desired.entries) {
      if (_details.containsKey(entry.key)) continue;
      final request = entry.value;
      while (workingSetBytes + request.maximumBytes > maximumBytes &&
          _details.isNotEmpty) {
        final obsolete = _details.keys.where(
          (key) => !desired.containsKey(key),
        );
        if (obsolete.isEmpty) break;
        final image = _details.remove(obsolete.first)!;
        _publish();
        _retire(image);
      }
      if (workingSetBytes + request.maximumBytes > maximumBytes) continue;
      final allocation = _resources.reserveRegionBytes(request.maximumBytes);
      if (allocation == null) continue;
      _activeKey = entry.key;
      _reservedBytes = request.maximumBytes;
      try {
        final image = await _run<RegionImage>(
          () => _decoder!.decodeRegion(request),
          (image) => image.dispose(),
        );
        _reservedBytes = 0;
        if (image == null) {
          allocation.dispose();
          return false;
        }
        if (_demand == null ||
            !_demand!.load ||
            !_requests(_demand!.viewport).containsKey(entry.key)) {
          image.dispose();
          allocation.dispose();
          return false;
        }
        final expectedWidth = (request.read.width / math.pow(2, request.level))
            .ceil();
        final expectedHeight =
            (request.read.height / math.pow(2, request.level)).ceil();
        if (image.bytes > request.maximumBytes ||
            image.image.width != expectedWidth ||
            image.image.height != expectedHeight ||
            image.sourceRect != request.read ||
            image.core != request.core) {
          image.dispose();
          throw StateError('区域后端返回的采样或坐标超出约定');
        }
        allocation.shrinkTo(image.bytes);
        _allocations[image] = allocation;
        _details[entry.key] = image;
        _publish();
      } catch (error) {
        _reservedBytes = 0;
        allocation.dispose();
        _fail(error);
      } finally {
        _activeKey = null;
      }
      return !_failed;
    }
    return false;
  }

  Map<(int, int, int), RegionRequest> _requests(ContentViewport viewport) {
    final bounds = Offset.zero & _decoder!.sourceSize;
    final visible = viewport.sourceRect.intersect(bounds);
    if (visible.isEmpty) return {};
    final scale = viewport.physicalScale;
    if (!scale.isFinite || scale <= 0) return {};
    final level = math.max(
      0,
      (math.log(1 / math.min(1.0, scale)) / math.ln2).floor(),
    );
    if (coalesceViewport) {
      final factor = (1 << level).toDouble();
      final step = factor * 64;
      final core = Rect.fromLTRB(
        (visible.left / step).floor() * step,
        (visible.top / step).floor() * step,
        (visible.right / step).ceil() * step,
        (visible.bottom / step).ceil() * step,
      ).intersect(bounds);
      final align = factor * 2;
      final read = Rect.fromLTRB(
        ((core.left - align) / align).floor() * align,
        ((core.top - align) / align).floor() * align,
        ((core.right + align) / align).ceil() * align,
        ((core.bottom + align) / align).ceil() * align,
      ).intersect(bounds);
      final key = (
        level,
        (core.left * bounds.height + core.top).toInt(),
        (core.right * bounds.height + core.bottom).toInt(),
      );
      return {key: RegionRequest(level: level, core: core, read: read)};
    }
    final step = tileSize * math.pow(2, level).toDouble();
    final overlap = math.pow(2, level).toDouble();
    final requests = <(int, int, int), RegionRequest>{};
    for (
      var row = (visible.top / step).floor();
      row < (visible.bottom / step).ceil();
      row++
    ) {
      for (
        var column = (visible.left / step).floor();
        column < (visible.right / step).ceil();
        column++
      ) {
        final core = Rect.fromLTWH(
          column * step,
          row * step,
          step,
          step,
        ).intersect(bounds);
        requests[(level, column, row)] = RegionRequest(
          level: level,
          core: core,
          read: core.inflate(overlap).intersect(bounds),
        );
      }
    }
    return requests;
  }

  Future<T?> _run<T extends Object>(
    Future<T> Function() create,
    void Function(T) dispose, {
    bool preprocessing = false,
  }) async {
    final lease = _source.retain();
    final work = _resources.schedule<T>(
      create,
      dispose: dispose,
      owner: this,
      preprocessing: preprocessing,
    );
    _work = work;
    try {
      return await work.result;
    } finally {
      await work.drained;
      await lease.dispose();
      if (identical(_work, work)) _work = null;
    }
  }

  void _discardDetails() {
    final retired = _details.values.toList();
    _details.clear();
    _publish();
    for (final image in retired) {
      _retire(image);
    }
  }

  void _retire(RegionImage image) {
    _retired.add(image);
    if (_surfaces == 0) {
      _releaseRetired();
    } else {
      _retirement ??= Completer<void>();
      if (!_retirementScheduled) {
        _retirementScheduled = true;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          _retirementScheduled = false;
          _releaseRetired();
        });
        SchedulerBinding.instance.ensureVisualUpdate();
      }
    }
  }

  void _releaseRetired() {
    for (final image in _retired) {
      image.dispose();
      _allocations.remove(image)?.dispose();
    }
    _retired.clear();
    _retirement?.complete();
    _retirement = null;
  }

  VoidCallback attachSurface() {
    _surfaces++;
    var attached = true;
    return () {
      if (!attached) return;
      attached = false;
      if (--_surfaces == 0) _releaseRetired();
    };
  }

  void _fail(Object error) {
    if (_disposed) return;
    _failed = true;
    _publish(error: error);
  }

  void _publish({Object? error}) {
    if (_disposed) return;
    _value = RegionContentState(
      sourceSize: _decoder?.sourceSize,
      version: _source.version,
      images: List.unmodifiable([
        ?_base,
        ..._details.values,
      ]),
      error: error,
      loading: _base == null && error == null,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _work?.cancel();
    _resources.removeMemoryListener(_schedule);
    _value = const RegionContentState(loading: false);
    notifyListeners();
    unawaited(_close());
    super.dispose();
  }

  Future<void> _close() async {
    try {
      try {
        await _operation;
      } finally {
        try {
          try {
            final decoder = _decoder;
            decoder?.dispose();
            if (decoder is DrainingRegionImageDecoder) await decoder.drained;
          } finally {
            if (_backend case final OwnedRegionImageBackend backend) {
              await backend.close();
            }
          }
        } finally {
          // worker 退出报错仍须退役已发布图片、归还预算并释放来源。
          _decoder = null;
          if (_base case final image?) _retire(image);
          _base = null;
          for (final image in _details.values) {
            _retire(image);
          }
          _details.clear();
          _reservedBytes = 0;
          try {
            await _retirement?.future;
          } finally {
            await _source.dispose();
          }
        }
      }
      _drained.complete();
    } catch (error, stack) {
      _drained.completeError(error, stack);
    }
  }
}

class RegionImageSurface extends StatefulWidget {
  const RegionImageSurface({
    super.key,
    required this.session,
    this.filterQuality = FilterQuality.low,
    this.color,
    this.colorBlendMode,
  });
  final RegionContentSession session;
  final FilterQuality filterQuality;
  final Color? color;
  final BlendMode? colorBlendMode;

  @override
  State<RegionImageSurface> createState() => _RegionImageSurfaceState();
}

class _RegionImageSurfaceState extends State<RegionImageSurface> {
  late VoidCallback _detach;
  @override
  void initState() {
    super.initState();
    _detach = widget.session.attachSurface();
  }

  @override
  void didUpdateWidget(RegionImageSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _detach();
      _detach = widget.session.attachSurface();
    }
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _RegionPainter(
      widget.session,
      widget.filterQuality,
      widget.color,
      widget.colorBlendMode,
    ),
  );
}

class _RegionPainter extends CustomPainter {
  _RegionPainter(
    this.session,
    this.filterQuality,
    this.color,
    this.colorBlendMode,
  ) : super(repaint: session);
  final RegionContentSession session;
  final FilterQuality filterQuality;
  final Color? color;
  final BlendMode? colorBlendMode;

  @override
  void paint(Canvas canvas, Size size) {
    final state = session.value;
    final source = state.sourceSize;
    if (source == null || source.isEmpty) return;
    canvas
      ..save()
      ..scale(size.width / source.width, size.height / source.height);
    for (var index = 0; index < state.images.length; index++) {
      final layer = state.images[index];
      canvas
        ..save()
        ..clipRect(layer.core, doAntiAlias: false);
      // 同一来源的细节替换基础层；半透明像素不能多次 source-over 合成。
      // 用互斥绘制区域避免为整张图另建离屏合成 surface。
      for (var above = index + 1; above < state.images.length; above++) {
        canvas.clipRect(
          state.images[above].core,
          clipOp: ui.ClipOp.difference,
          doAntiAlias: false,
        );
      }
      canvas
        ..drawImageRect(
          layer.image,
          Rect.fromLTWH(
            0,
            0,
            layer.image.width.toDouble(),
            layer.image.height.toDouble(),
          ),
          layer.sourceRect,
          Paint()
            ..filterQuality = filterQuality
            ..colorFilter = color == null
                ? null
                : ColorFilter.mode(color!, colorBlendMode ?? BlendMode.srcIn),
        )
        ..restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RegionPainter oldDelegate) =>
      oldDelegate.session != session ||
      oldDelegate.filterQuality != filterQuality ||
      oldDelegate.color != color ||
      oldDelegate.colorBlendMode != colorBlendMode;
}
