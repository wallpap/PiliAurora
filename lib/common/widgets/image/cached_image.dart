import 'dart:async';
import 'dart:collection';
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image_ce/cached_network_image.dart'
    show BaseCacheManager, DefaultCacheManager, FileInfo;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

/// 复用磁盘缓存，由 Flutter 管理解码器、帧和图片缓存的生命周期。
class CachedImageProvider extends ImageProvider<CachedImageProvider> {
  const CachedImageProvider(
    this.url, {
    this.cacheManager,
    this.width,
    this.height,
    this.maxDecodePixels,
    this.scale = 1,
  }) : assert(width == null || width > 0),
       assert(height == null || height > 0),
       assert(maxDecodePixels == null || maxDecodePixels > 0);

  final String url;
  final BaseCacheManager? cacheManager;
  final int? width;
  final int? height;
  final int? maxDecodePixels;
  final double scale;

  // 同一张图在不同卡片尺寸下有不同的解码缓存，但应共享正在进行的下载。
  // 这里只保存进行中的任务；完成或失败后立即移除。
  static final _pendingFiles = <(BaseCacheManager, String), Future<File>>{};

  Future<File> _getFile() {
    final manager = cacheManager ?? DefaultCacheManager.instance!;
    final key = (manager, url);
    return _pendingFiles.putIfAbsent(key, () {
      final result = Completer<File>();
      // 先显示可用的磁盘缓存。继续消费流，让过期文件在后台更新，
      // 避免离线时已有图片也必须等待网络；更新后的文件供后续加载使用。
      unawaited(_readFileStream(manager, result, key));
      return result.future;
    });
  }

  Future<void> _readFileStream(
    BaseCacheManager manager,
    Completer<File> result,
    (BaseCacheManager, String) key,
  ) async {
    final operation = Diagnostics.instance.begin('imageFile', '读取图片文件');
    try {
      await for (final event in manager.getFileStream(url)) {
        if (event is FileInfo && !result.isCompleted) {
          result.complete(event.file);
        }
      }
      if (!result.isCompleted) throw StateError('图片缓存没有返回文件');
    } catch (error, stack) {
      operation?.finish(error: error);
      // 已显示旧缓存时，后台刷新失败不应移除可用图片。
      if (!result.isCompleted) result.completeError(error, stack);
    } finally {
      operation?.finish();
      _pendingFiles.remove(key);
    }
  }

  @override
  Future<CachedImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<CachedImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    CachedImageProvider key,
    ImageDecoderCallback decode,
  ) => _ImageCompleter(
    codec: _load(decode),
    scale: scale,
    debugLabel: url,
  );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    TraceOperation? operation;
    try {
      final file = await _getFile();
      operation = Diagnostics.instance.begin(
        'imageDecode',
        '创建图片解码器',
        details: {
          'width': width,
          'height': height,
          'maxPixels': maxDecodePixels,
        },
      );
      // 直接映射缓存文件，避免 readAsBytes 与 ImmutableBuffer 各持有一份数据。
      final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
      final codec = await decode(
        buffer,
        getTargetSize:
            width != null || height != null || maxDecodePixels != null
            ? _targetSize
            : null,
      );
      return codec;
    } catch (error) {
      operation?.finish(error: error);
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      rethrow;
    } finally {
      operation?.finish();
    }
  }

  ui.TargetImageSize _targetSize(int sourceWidth, int sourceHeight) {
    var ratio = 1.0;
    if (width != null) ratio = math.min(ratio, width! / sourceWidth);
    if (height != null) ratio = math.min(ratio, height! / sourceHeight);
    if (maxDecodePixels case final limit?) {
      ratio = math.min(ratio, math.sqrt(limit / (sourceWidth * sourceHeight)));
    }
    return ui.TargetImageSize(
      width: math.max(1, (sourceWidth * ratio).floor()),
      height: math.max(1, (sourceHeight * ratio).floor()),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CachedImageProvider &&
      url == other.url &&
      cacheManager == other.cacheManager &&
      width == other.width &&
      height == other.height &&
      maxDecodePixels == other.maxDecodePixels &&
      scale == other.scale;

  @override
  int get hashCode =>
      Object.hash(url, cacheManager, width, height, maxDecodePixels, scale);
}

/// 滚动或刷新可能早于文件读取完成；缓存和监听者都退出后，迟到的 codec
/// 也必须释放。只移除监听时不能释放仍被 ImageCache 保活的动图。
class _ImageCompleter extends MultiFrameImageStreamCompleter {
  factory _ImageCompleter({
    required Future<ui.Codec> codec,
    required double scale,
    required String debugLabel,
  }) {
    final owner = _CodecOwner();
    return _ImageCompleter._(
      owner,
      codec.then(owner.attach),
      scale,
      debugLabel,
    );
  }

  _ImageCompleter._(
    this._owner,
    Future<ui.Codec> codec,
    double scale,
    String debugLabel,
  ) : super(codec: codec, scale: scale, debugLabel: debugLabel);

  final _CodecOwner _owner;
  int _handles = 0;
  bool _hadListener = false;

  @override
  void addListener(ImageStreamListener listener) {
    _hadListener = true;
    super.addListener(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    _releaseIfUnused();
  }

  @override
  ImageStreamCompleterHandle keepAlive() {
    _handles++;
    return _ImageHandle(super.keepAlive(), () {
      _handles--;
      _releaseIfUnused();
    });
  }

  void _releaseIfUnused() {
    if (_hadListener && !hasListeners && _handles == 0) _owner.dispose();
  }
}

class _ImageHandle implements ImageStreamCompleterHandle {
  _ImageHandle(this._delegate, this._onDispose);

  final ImageStreamCompleterHandle _delegate;
  final VoidCallback _onDispose;

  @override
  void dispose() {
    _delegate.dispose();
    _onDispose();
  }
}

class _CodecOwner {
  _ThrottledCodec? _codec;
  bool _disposed = false;

  ui.Codec attach(ui.Codec codec) {
    final managed = _codec = _ThrottledCodec(codec);
    if (_disposed) managed.dispose();
    return managed;
  }

  void dispose() {
    _disposed = true;
    _codec?.dispose();
    _codec = null;
  }
}

/// 延续原组件的动图帧率限制，避免短帧 GIF 持续占用 CPU。
class _ThrottledCodec implements ui.Codec {
  _ThrottledCodec(this._codec) {
    Diagnostics.instance.gauge('imageCodecs', ++_activeCodecs);
  }

  static int _activeCodecs = 0;

  final ui.Codec _codec;
  bool _disposed = false;
  bool _firstFrame = true;
  _FrameAdmission? _admission;

  @override
  int get frameCount => _codec.frameCount;

  @override
  int get repetitionCount => _codec.repetitionCount;

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    final operation = Diagnostics.instance.begin('imageFrame', '解码图片帧');
    try {
      final frame = await _codec.getNextFrame();
      operation?.finish(
        details: {
          'width': frame.image.width,
          'height': frame.image.height,
          'rgbaBytes': frame.image.width * frame.image.height * 4,
        },
      );
      if (_firstFrame && !_disposed) {
        _firstFrame = false;
        // 按解码字节数分批交付首帧，避免图片更新集中到同一个绘制周期。
        final admission = _admission = _FrameBudget.admit(
          frame.image.width * frame.image.height * 4,
        );
        await admission.ready;
        _admission = null;
      }
      if (_disposed) {
        frame.image.dispose();
        return frame;
      }
      return frameCount > 1 &&
              frame.duration < const Duration(milliseconds: 100)
          ? _SlowFrame(frame.image)
          : frame;
    } catch (error) {
      operation?.finish(error: error);
      rethrow;
    } finally {
      operation?.finish();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _admission?.cancel();
    _admission = null;
    Diagnostics.instance.gauge('imageCodecs', --_activeCodecs);
    _codec.dispose();
  }
}

class _SlowFrame implements ui.FrameInfo {
  _SlowFrame(this.image);

  @override
  final ui.Image image;

  @override
  Duration get duration => const Duration(milliseconds: 100);
}

/// 图片首次可用时淡入一次；淡入结束后只返回图片本身，不再保留过渡层。
///
/// 图片和占位共用一个控制器，保留独立的淡入、淡出时长；
/// 动画结束后移除过渡结构，避免继续保留透明度合成层。
class _ImageFadeIn extends StatefulWidget {
  const _ImageFadeIn({
    super.key,
    required this.child,
    required this.placeholder,
    required this.duration,
    required this.fadeOutDuration,
    required this.ready,
    required this.animate,
  });

  /// 已解码的图片子树（`Image.frameBuilder` 的 child）。
  final Widget child;

  /// 图片尚未可用时显示的内容。
  final Widget placeholder;

  /// 淡入时长；[Duration.zero] 表示直接显示。
  final Duration duration;
  final Duration fadeOutDuration;

  /// 图片是否已经可用。
  final bool ready;

  /// 是否播放淡入；同步命中缓存时为 false。
  final bool animate;

  @override
  State<_ImageFadeIn> createState() => _ImageFadeInState();
}

class _ImageFadeInState extends State<_ImageFadeIn>
    with SingleTickerProviderStateMixin {
  /// 惰性创建：同步命中缓存的图片不淡入，就不该为它建控制器。
  AnimationController? _fade;

  AnimationController get _controller =>
      _fade ??= AnimationController(vsync: this, duration: _transitionDuration)
        ..addStatusListener(_onStatusChanged);

  Duration get _transitionDuration => Duration(
    microseconds: math.max(
      widget.duration.inMicroseconds,
      widget.fadeOutDuration.inMicroseconds,
    ),
  );

  late Animation<double> _imageOpacity;
  late Animation<double> _placeholderOpacity;

  /// 淡入已结束：子树退回普通结构，不再有过渡层。
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _startIfReady();
  }

  @override
  void didUpdateWidget(_ImageFadeIn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.ready) {
      // 图片再次不可用（例如换了 URL）：回到占位，下次可用时重新淡入。
      _fade?.reset();
      _done = false;
      return;
    }
    if (!widget.animate || _transitionDuration == Duration.zero) {
      _fade?.stop();
      _done = true;
      return;
    }
    if (!oldWidget.ready) {
      _startIfReady();
    } else if (!_done &&
        (widget.duration != oldWidget.duration ||
            widget.fadeOutDuration != oldWidget.fadeOutDuration)) {
      _configureOpacities();
      _controller.forward();
    }
  }

  void _startIfReady() {
    if (!widget.ready) return;
    // didUpdateWidget 之后紧接着就会 build，无需 setState。
    if (!widget.animate || _transitionDuration == Duration.zero) {
      _fade?.stop();
      _done = true;
      return;
    }
    _done = false;
    _configureOpacities();
    _controller.forward(from: 0);
  }

  void _configureOpacities() {
    _controller.duration = _transitionDuration;
    _imageOpacity = _opacity(widget.duration);
    _placeholderOpacity = _opacity(widget.fadeOutDuration, reverse: true);
  }

  Animation<double> _opacity(Duration duration, {bool reverse = false}) {
    if (duration == Duration.zero) {
      return AlwaysStoppedAnimation(reverse ? 0 : 1);
    }
    final opacity = _controller.drive(
      CurveTween(
        curve: Interval(
          0,
          duration.inMicroseconds / _transitionDuration.inMicroseconds,
        ),
      ),
    );
    return reverse ? opacity.drive(Tween<double>(begin: 1, end: 0)) : opacity;
  }

  void _onStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      setState(() => _done = true);
    }
  }

  @override
  void dispose() {
    _fade?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.ready) return widget.placeholder;
    if (_done) return widget.child;
    return Stack(
      alignment: Alignment.center,
      children: [
        if (widget.fadeOutDuration != Duration.zero)
          FadeTransition(
            opacity: _placeholderOpacity,
            child: widget.placeholder,
          ),
        if (widget.duration == Duration.zero)
          widget.child
        else
          FadeTransition(opacity: _imageOpacity, child: widget.child),
      ],
    );
  }
}

class CachedImage extends StatelessWidget {
  const CachedImage({
    super.key,
    required this.imageUrl,
    this.cacheManager,
    this.width,
    this.height,
    this.memCacheWidth,
    this.memCacheHeight,
    this.maxDecodePixels = 1 << 20,
    this.fit,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.low,
    this.color,
    this.colorBlendMode,
    this.placeholder,
    this.errorBuilder,
    this.fadeInDuration = const Duration(milliseconds: 120),
    this.fadeOutDuration = const Duration(milliseconds: 120),
  });

  final String imageUrl;
  final BaseCacheManager? cacheManager;
  final double? width;
  final double? height;
  final int? memCacheWidth;
  final int? memCacheHeight;
  final int? maxDecodePixels;
  final BoxFit? fit;
  final Alignment alignment;
  final FilterQuality filterQuality;
  final Color? color;
  final BlendMode? colorBlendMode;
  final Widget Function(BuildContext, String)? placeholder;
  final ImageErrorWidgetBuilder? errorBuilder;
  final Duration fadeInDuration;
  final Duration fadeOutDuration;

  @override
  Widget build(BuildContext context) => Image(
    image: CachedImageProvider(
      imageUrl,
      cacheManager: cacheManager,
      width: memCacheWidth,
      height: memCacheHeight,
      maxDecodePixels: maxDecodePixels,
    ),
    width: width,
    height: height,
    fit: fit,
    alignment: alignment,
    filterQuality: filterQuality,
    color: color,
    colorBlendMode: colorBlendMode,
    errorBuilder: errorBuilder ?? (context, _, _) => _placeholder(context),
    frameBuilder: (context, child, frame, synchronouslyLoaded) => _ImageFadeIn(
      key: ValueKey(imageUrl),
      ready: frame != null,
      // 同步命中缓存时直接显示，与原来 `if (synchronouslyLoaded) return child;` 一致。
      animate: !synchronouslyLoaded,
      duration: fadeInDuration,
      fadeOutDuration: fadeOutDuration,
      placeholder: _placeholder(context),
      child: child,
    ),
  );

  Widget _placeholder(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: placeholder?.call(context, imageUrl),
  );
}

/// 按绘制周期分批交付图片首帧；不限制原生解码或保证 GPU 耗时。
abstract final class _FrameBudget {
  /// 每帧首帧交付的字节预算；单张超预算图片独占一批，避免永久等待。
  static const int _bytesPerFrame = 6 << 20;

  static int _bytes = 0;
  static bool _resetScheduled = false;
  static final _pending = Queue<_FrameAdmission>();

  static _FrameAdmission admit(int bytes) {
    final admission = _FrameAdmission(bytes);
    _pending.add(admission);
    _drain();
    return admission;
  }

  static void cancel(_FrameAdmission admission) {
    _pending.remove(admission);
    if (!admission._ready.isCompleted) admission._ready.complete();
    _drain();
  }

  static void _drain() {
    while (_pending.isNotEmpty &&
        (_bytes == 0 || _bytes + _pending.first.bytes <= _bytesPerFrame)) {
      final admission = _pending.removeFirst();
      _bytes += admission.bytes;
      admission._ready.complete();
    }
    if (_bytes == 0 || _resetScheduled) return;
    _resetScheduled = true;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        _bytes = 0;
        _resetScheduled = false;
        _drain();
      })
      ..ensureVisualUpdate();
  }
}

class _FrameAdmission {
  _FrameAdmission(this.bytes);

  final int bytes;
  final _ready = Completer<void>();

  Future<void> get ready => _ready.future;

  void cancel() => _FrameBudget.cancel(this);
}
