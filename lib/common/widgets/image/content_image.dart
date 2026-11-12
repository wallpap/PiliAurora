import 'dart:io' show File;

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
    if (oldWidget.image != widget.image) {
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
      _detach();
      _replace(null);
      return;
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
