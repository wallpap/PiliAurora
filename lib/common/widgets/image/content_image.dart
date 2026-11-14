import 'dart:io' show File;
import 'dart:async';

import 'package:pili_aurora/utils/cache_manager.dart' show CacheManager;
import 'package:pili_aurora/common/widgets/image/image_resources.dart';
import 'package:pili_aurora/common/widgets/image/src/image_source_store.dart';
import 'package:pili_aurora/common/widgets/image/src/region_content_session.dart';
import 'package:pili_aurora/common/widgets/image/src/native_worker_backend.dart';
import 'package:pili_aurora/services/logger.dart';

import 'package:cached_network_image_ce/cached_network_image.dart'
    show BaseCacheManager;
import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';
import 'package:pili_aurora/common/widgets/image/src/content_demand.dart';

class ContentImage extends StatefulWidget {
  const ContentImage({
    super.key,
    required this.image,
    this.sourceSize,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.low,
    this.placeholder,
    this.errorBuilder,
    this.builder,
    this.viewport,
    this.onDemandChanged,
    this.color,
    this.colorBlendMode,
  });

  ContentImage.network(
    String url, {
    super.key,
    BaseCacheManager? cacheManager,
    this.sourceSize,
    this.width,
    this.height,
    int? memCacheWidth,
    int? memCacheHeight,
    int? maxDecodePixels,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.low,
    this.placeholder,
    this.errorBuilder,
    this.builder,
    this.viewport,
    this.onDemandChanged,
    this.color,
    this.colorBlendMode,
  }) : image = CachedImageProvider(
         url,
         cacheManager: cacheManager,
         width: memCacheWidth,
         height: memCacheHeight,
         maxDecodePixels: maxDecodePixels,
       );

  ContentImage.file(
    File file, {
    super.key,
    this.sourceSize,
    this.width,
    this.height,
    int? memCacheWidth,
    int? memCacheHeight,
    int? maxDecodePixels,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.low,
    this.placeholder,
    this.errorBuilder,
    this.builder,
    this.viewport,
    this.onDemandChanged,
    this.color,
    this.colorBlendMode,
  }) : image = LocalImageProvider(
         file,
         width: memCacheWidth,
         height: memCacheHeight,
         maxDecodePixels: maxDecodePixels,
       );

  final ImageProvider image;
  final Size? sourceSize;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Alignment alignment;
  final FilterQuality filterQuality;
  final WidgetBuilder? placeholder;
  final ImageErrorWidgetBuilder? errorBuilder;
  final Widget Function(BuildContext, Widget, Size)? builder;
  final ValueListenable<ContentViewport?>? viewport;
  final ValueChanged<ContentDemand>? onDemandChanged;
  final Color? color;
  final BlendMode? colorBlendMode;

  @override
  State<ContentImage> createState() => _ContentImageState();
}

class _ContentImageState extends State<ContentImage> {
  RegionContentSession? _region;
  bool _regionChecked = false;
  bool _regionStarting = false;
  ImageWork<NativeWorkerDecoder>? _nativeOpen;

  void _disposeRegion() {
    _nativeOpen?.cancel();
    _nativeOpen = null;
    final region = _region;
    _region = null;
    region?.removeListener(_regionChanged);
    if (region != null) unawaited(_drainRegion(region));
    region?.dispose();
  }

  Future<void> _drainRegion(RegionContentSession region) async {
    try {
      await region.drained;
    } catch (error, stack) {
      logger.w('区域图片释放失败', error: error.runtimeType, stackTrace: stack);
    }
  }

  Future<void> _fallbackRegion(RegionContentSession region) async {
    final generation = _generation;
    _sourceSize = region.value.sourceSize ?? _sourceSize;
    _regionStarting = true;
    _disposeRegion();
    // 明确的能力回退也先等待旧进程退出，避免与完整帧叠加峰值。
    await _drainRegion(region);
    if (!mounted || generation != _generation) return;
    setState(() {
      _regionStarting = false;
      _error = null;
      _stack = null;
      _sync();
    });
  }

  void _regionChanged() {
    if (!mounted || _region == null) return;
    final region = _region!;
    if (region.value.error is UnsupportedError) {
      // 监听回调返回后再释放 ChangeNotifier，避免在 notifyListeners 内 dispose。
      scheduleMicrotask(() {
        if (!mounted || !identical(_region, region)) return;
        unawaited(_fallbackRegion(region));
      });
      return;
    }
    setState(() {
      _sourceSize = _region!.value.sourceSize ?? _sourceSize;
      _error = _region!.value.error;
    });
    if (region.value.error != null) {
      scheduleMicrotask(() {
        if (mounted && identical(_region, region)) {
          setState(_disposeRegion);
        }
      });
    }
  }

  Future<void> _startRegion() async {
    _regionChecked = true;
    _regionStarting = true;
    final generation = ++_generation;
    ImageSourceLease? lease;
    NativeWorkerDecoder? decoder;
    try {
      final provider = widget.image;
      final file = switch (provider) {
        CachedImageProvider() => await provider.getSourceFile(),
        LocalImageProvider() => provider.file,
        _ => throw UnsupportedError('此来源保留完整帧路径'),
      };
      if (!mounted || generation != _generation) return;
      if (!await NativeWorkerDecoder.supportsFile(file)) {
        throw UnsupportedError('此格式保留完整帧路径');
      }
      if (!mounted || generation != _generation) return;
      lease = await CacheManager.imageSources.acquire(file);
      if (!mounted || generation != _generation) return;
      final retainedSource = lease;
      final work = ImageResources.shared.schedule<NativeWorkerDecoder>(
        () => NativeWorkerDecoder.open(retainedSource),
        dispose: (value) => value.dispose(),
        owner: this,
        preprocessing: true,
      );
      _nativeOpen = work;
      decoder = await work.result;
      await work.drained;
      if (identical(_nativeOpen, work)) _nativeOpen = null;
      if (decoder == null || !mounted || generation != _generation) return;
      if (decoder.frameCount != 1 || !decoder.hasBoundedBase) {
        decoder.dispose();
        await decoder.drained;
        decoder = null;
        return;
      }
      _sourceSize = decoder.sourceSize;
      final region = RegionContentSession(
        source: lease,
        backend: PreparedNativeBackend(decoder),
        maximumBytes: 48 << 20,
        maximumBaseBytes: 32 << 20,
        coalesceViewport: true,
      );
      lease = null;
      decoder = null;
      _region = region;
      region.addListener(_regionChanged);
      if (widget.viewport?.value case final viewport?) {
        region.update(
          ContentDemand(viewport: viewport, load: _load, animate: false),
        );
      }
      setState(() {});
    } on UnsupportedError {
      // 后端缺少格式能力时，open 已排空进程；finally 接回原完整帧路径。
    } catch (error, stack) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error;
          _stack = stack;
        });
      }
    } finally {
      if (decoder != null) {
        decoder.dispose();
        try {
          await decoder.drained;
        } catch (error, stack) {
          logger.w('区域图片准备取消', error: error.runtimeType, stackTrace: stack);
        }
      }
      await lease?.dispose();
      if (mounted && generation == _generation) {
        _regionStarting = false;
        if (_region == null && _error == null) _sync();
      }
    }
  }

  ImageStream? _stream;
  ImageInfo? _info;
  ImageStreamCompleterHandle? _handle;
  ImageStreamListener? _listener;
  Object? _error;
  StackTrace? _stack;
  Size? _sourceSize;
  bool _listening = false;
  bool _animate = true;
  bool _load = true;
  int _generation = 0;
  bool _visible = true;
  bool _demandScheduled = false;
  final _positions = <ScrollPosition>{};

  @override
  void initState() {
    super.initState();
    widget.viewport?.addListener(_updateViewport);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listenToScroll();
    _sync();
    _scheduleDemand();
  }

  @override
  void didUpdateWidget(ContentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewport != widget.viewport) {
      oldWidget.viewport?.removeListener(_updateViewport);
      widget.viewport?.addListener(_updateViewport);
      _visible = true;
      _listenToScroll();
    }
    if (oldWidget.image != widget.image ||
        (oldWidget.viewport != null && widget.viewport == null)) {
      _disposeRegion();
      _regionChecked = false;
      _regionStarting = false;
      _detach();
      _sourceSize = null;
      _error = null;
      _stack = null;
      _replace(null);
    }
    _sync();
    _scheduleDemand();
  }

  void _sync() {
    _load = ImageLoadingScope.isEnabled(context) && _visible;
    _animate = TickerMode.valuesOf(context).enabled && _visible;
    if (!_load) {
      _disposeRegion();
      _regionChecked = false;
      _regionStarting = false;
      _detach();
      _replace(null);
      return;
    }
    if (_region != null) {
      if (widget.viewport?.value case final viewport?) {
        _region!.update(
          ContentDemand(viewport: viewport, load: _load, animate: false),
        );
      }
      return;
    }
    if (_regionChecked && _error != null) return;
    final provider = widget.image;
    final nativeSource = switch (provider) {
      CachedImageProvider() =>
        provider.width == null &&
            provider.height == null &&
            provider.maxDecodePixels == null &&
            provider.decodeTarget == null,
      LocalImageProvider() =>
        provider.width == null &&
            provider.height == null &&
            provider.maxDecodePixels == null &&
            provider.decodeTarget == null,
      _ => false,
    };
    if (NativeWorkerDecoder.executable != null &&
        widget.viewport != null &&
        nativeSource) {
      if (!_regionChecked && _load) {
        unawaited(_startRegion());
        return;
      }
      if (_regionStarting) return;
    }
    if (_stream == null) {
      final generation = ++_generation;
      _stream = widget.image.resolve(createLocalImageConfiguration(context));
      _listener = ImageStreamListener(
        (info, _) {
          if (!mounted || generation != _generation) {
            info.dispose();
            return;
          }
          setState(() {
            final completer = _stream?.completer;
            _sourceSize =
                (completer is ImageSourceMetadata
                    ? (completer as ImageSourceMetadata).sourceSize
                    : null) ??
                _unscaledSourceSize(info) ??
                _sourceSize ??
                widget.sourceSize ??
                Size(info.image.width.toDouble(), info.image.height.toDouble());
            _replace(info);
            _error = null;
            _stack = null;
          });
          _scheduleDemand();
          if (!_animate) _pause();
        },
        onError: (Object error, StackTrace? stack) {
          if (!mounted || generation != _generation) return;
          setState(() {
            _error = error;
            _stack = stack;
          });
        },
      );
    }
    if (_animate || _info == null) {
      if (!_listening) {
        _listening = true;
        final previousHandle = _handle;
        _handle = null;
        _stream!.addListener(_listener!);
        previousHandle?.dispose();
      }
    } else {
      _pause();
    }
  }

  Size? _unscaledSourceSize(ImageInfo info) {
    final provider = widget.image;
    if ((provider is CachedImageProvider &&
            provider.width == null &&
            provider.height == null &&
            provider.maxDecodePixels == null &&
            provider.decodeTarget == null) ||
        (provider is LocalImageProvider &&
            provider.width == null &&
            provider.height == null &&
            provider.maxDecodePixels == null &&
            provider.decodeTarget == null)) {
      return Size(info.image.width.toDouble(), info.image.height.toDouble());
    }
    return null;
  }

  void _pause() {
    if (!_listening) return;
    _handle ??= _stream!.completer?.keepAlive();
    _stream!.removeListener(_listener!);
    _listening = false;
  }

  void _detach() {
    _generation++;
    if (_listening) _stream?.removeListener(_listener!);
    _handle?.dispose();
    _handle = null;
    _listening = false;
    _stream = null;
    _listener = null;
  }

  void _replace(ImageInfo? info) {
    final previous = _info;
    _info = info;
    if (previous != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
  }

  void _listenToScroll() {
    for (final position in _positions) {
      position.removeListener(_scheduleDemand);
    }
    _positions.clear();
    if (widget.viewport != null) return;
    context.visitAncestorElements((element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        final position = (element.state as ScrollableState).position;
        if (_positions.add(position)) position.addListener(_scheduleDemand);
      }
      return true;
    });
  }

  void _scheduleDemand() {
    if (_demandScheduled || widget.viewport != null) return;
    _demandScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _demandScheduled = false;
      if (!mounted) return;
      final source = _sourceSize ?? widget.sourceSize;
      final box = context.findRenderObject();
      if (source == null ||
          source.isEmpty ||
          box is! RenderBox ||
          !box.hasSize ||
          box.size.isEmpty) {
        return;
      }
      final global = MatrixUtils.transformRect(
        box.getTransformTo(null),
        Offset.zero & box.size,
      );
      var visible = global;
      RenderObject child = box;
      RenderObject? ancestor = child.parent;
      while (ancestor != null) {
        final clip = ancestor.describeApproximatePaintClip(child);
        if (clip != null) {
          visible = visible.intersect(
            MatrixUtils.transformRect(ancestor.getTransformTo(null), clip),
          );
        }
        child = ancestor;
        ancestor = ancestor.parent;
      }
      final local = visible.isEmpty
          ? Rect.zero
          : Rect.fromPoints(
              box.globalToLocal(visible.topLeft),
              box.globalToLocal(visible.bottomRight),
            );
      final fitted = applyBoxFit(widget.fit, source, box.size);
      final destination = widget.alignment.inscribe(
        fitted.destination,
        Offset.zero & box.size,
      );
      final input = widget.alignment.inscribe(
        fitted.source,
        Offset.zero & source,
      );
      final clipped = local.intersect(destination);
      final ratioX = input.width / destination.width;
      final ratioY = input.height / destination.height;
      final rectangle = clipped.isEmpty
          ? Rect.zero
          : Rect.fromLTWH(
              input.left + (clipped.left - destination.left) * ratioX,
              input.top + (clipped.top - destination.top) * ratioY,
              clipped.width * ratioX,
              clipped.height * ratioY,
            );
      _applyViewport(
        ContentViewport(
          rectangle,
          MediaQuery.devicePixelRatioOf(context) /
              (ratioX < ratioY ? ratioX : ratioY),
        ),
      );
    });
  }

  void _updateViewport() {
    if (widget.viewport?.value case final viewport?) _applyViewport(viewport);
  }

  void _applyViewport(ContentViewport viewport) {
    final visible = !viewport.sourceRect.isEmpty;
    if (_visible != visible) {
      setState(() {
        _visible = visible;
        _sync();
      });
    }
    _region?.update(
      ContentDemand(
        viewport: viewport,
        load: ImageLoadingScope.isEnabled(context) && visible,
        animate: false,
      ),
    );
    widget.onDemandChanged?.call(
      ContentDemand(
        viewport: viewport,
        load: ImageLoadingScope.isEnabled(context) && visible,
        animate: TickerMode.valuesOf(context).enabled && visible,
      ),
    );
  }

  @override
  void dispose() {
    widget.viewport?.removeListener(_updateViewport);
    for (final position in _positions) {
      position.removeListener(_scheduleDemand);
    }
    _disposeRegion();
    _detach();
    _replace(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = _sourceSize ?? widget.sourceSize ?? Size.zero;
    var width = widget.width;
    var height = widget.height;
    if (!source.isEmpty) {
      if (width != null && height == null) {
        height = width * source.height / source.width;
      }
      if (height != null && width == null) {
        width = height * source.width / source.height;
      }
    }
    Widget pixels;
    if (!_load) {
      pixels = SizedBox(width: width, height: height);
    } else if (_error != null) {
      pixels =
          widget.errorBuilder?.call(context, _error!, _stack) ??
          SizedBox(width: width, height: height);
    } else if (_region != null && _region!.value.images.isNotEmpty) {
      pixels = SizedBox(
        width: width,
        height: height,
        child: FittedBox(
          fit: widget.fit,
          alignment: widget.alignment,
          child: SizedBox(
            width: source.width,
            height: source.height,
            child: RegionImageSurface(
              session: _region!,
              filterQuality: widget.filterQuality,
              color: widget.color,
              colorBlendMode: widget.colorBlendMode,
            ),
          ),
        ),
      );
    } else if (_info == null) {
      pixels = SizedBox(
        width: width,
        height: height,
        child: widget.placeholder?.call(context),
      );
    } else {
      pixels = RawImage(
        image: _info!.image,
        scale: widget.builder != null && !source.isEmpty
            ? _info!.image.width / source.width
            : _info!.scale,
        width: width,
        height: height,
        fit: widget.fit,
        alignment: widget.alignment,
        filterQuality: widget.filterQuality,
        color: widget.color,
        colorBlendMode: widget.colorBlendMode,
      );
    }
    return Semantics(
      image: true,
      child: widget.builder?.call(context, pixels, source) ?? pixels,
    );
  }
}
