import 'dart:async';
import 'dart:collection';
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image_ce/cached_network_image.dart'
    show BaseCacheManager, DefaultCacheManager, FileInfo;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/common/widgets/image/image_resources.dart';
import 'package:pili_aurora/common/widgets/image/src/image_sampling.dart';

export 'src/image_sampling.dart' show ImageDecodeTarget;

/// 静态导出可在暂停动画时继续加载图片。
class ImageLoadingScope extends InheritedWidget {
  const ImageLoadingScope({
    super.key,
    required this.enabled,
    required super.child,
  });

  final bool enabled;

  static bool isEnabled(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ImageLoadingScope>()
          ?.enabled ??
      TickerMode.valuesOf(context).enabled;

  @override
  bool updateShouldNotify(ImageLoadingScope oldWidget) =>
      enabled != oldWidget.enabled;
}

/// 静态帧沿用 LRU；动图 codec 的隐含成本不在像素预算内，最后一个监听
/// 退出时交还缓存句柄。显式 keepAlive 仍可保留暂停中的动画。
class CachedImageCache extends ImageCache {
  final _entries = <Object, _ImageCacheEntry>{};

  @override
  ImageStreamCompleter? putIfAbsent(
    Object key,
    ImageStreamCompleter Function() loader, {
    ImageErrorListener? onError,
  }) {
    final completer = super.putIfAbsent(key, loader, onError: onError);
    if (completer is _ImageCompleter &&
        !identical(_entries[key]?.completer, completer)) {
      _entries.remove(key)?.detach();
      late _ImageCacheEntry entry;
      entry = _ImageCacheEntry(
        completer,
        onIdle: () {
          if (completer._animated && identical(_entries[key], entry)) {
            // 使用 ImageCache 收到的真实键，兼容 ResizeImage 等外层 provider。
            evict(key, includeLive: false);
          }
        },
        onRelease: () {
          if (identical(_entries[key], entry)) _entries.remove(key);
          entry.detach();
        },
      );
      _entries[key] = entry;
    }
    return completer;
  }

  @override
  bool evict(Object key, {bool includeLive = true}) {
    _entries.remove(key)?.detach();
    return super.evict(key, includeLive: includeLive);
  }

  @override
  void clear() {
    for (final entry in _entries.values) {
      entry.detach();
    }
    _entries.clear();
    super.clear();
  }
}

class _ImageCacheEntry {
  _ImageCacheEntry(
    this.completer, {
    required this.onIdle,
    required this.onRelease,
  }) {
    completer._onIdle.add(onIdle);
    completer._onRelease.add(onRelease);
  }

  final _ImageCompleter completer;
  final VoidCallback onIdle;
  final VoidCallback onRelease;

  void detach() {
    completer._onIdle.remove(onIdle);
    completer._onRelease.remove(onRelease);
  }
}

/// 复用磁盘缓存和 Flutter 图片缓存，统一管理解码器与帧的生命周期。
class CachedImageProvider extends ImageProvider<CachedImageProvider> {
  const CachedImageProvider(
    this.url, {
    this.cacheManager,
    this.width,
    this.height,
    this.maxDecodePixels,
    this.decodeTarget,
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
  final ImageDecodeTarget? decodeTarget;

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
  ) {
    final owner = _CodecOwner();
    return _ImageCompleter(
      owner,
      codec: _load(decode, owner),
      scale: scale,
      debugLabel: url,
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode, _CodecOwner owner) async {
    TraceOperation? operation;
    try {
      final file = await _getFile();
      return await owner.load(() async {
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
              width != null ||
                  height != null ||
                  maxDecodePixels != null ||
                  decodeTarget != null
              ? (sourceWidth, sourceHeight) {
                  owner.sourceSize = Size(
                    sourceWidth.toDouble(),
                    sourceHeight.toDouble(),
                  );
                  return _targetSize(sourceWidth, sourceHeight);
                }
              : null,
        );
        return codec;
      });
    } catch (error) {
      operation?.finish(error: error);
      if (error is! _ImageDecodeCancelled) {
        scheduleMicrotask(
          () => PaintingBinding.instance.imageCache.evict(this),
        );
      }
      rethrow;
    } finally {
      operation?.finish();
    }
  }

  ui.TargetImageSize _targetSize(int sourceWidth, int sourceHeight) {
    if (decodeTarget case final target?) {
      return target.targetSize(
        sourceWidth,
        sourceHeight,
        maximumPixels: maxDecodePixels,
      );
    }
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
      decodeTarget == other.decodeTarget &&
      scale == other.scale;

  @override
  int get hashCode => Object.hash(
    url,
    cacheManager,
    width,
    height,
    maxDecodePixels,
    scale,
    decodeTarget,
  );
}

class LocalImageProvider extends ImageProvider<LocalImageProvider> {
  const LocalImageProvider(
    this.file, {
    this.width,
    this.height,
    this.maxDecodePixels,
    this.scale = 1,
    this.decodeTarget,
  });

  final File file;
  final int? width;
  final int? height;
  final int? maxDecodePixels;
  final double scale;
  final ImageDecodeTarget? decodeTarget;

  @override
  Future<LocalImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    LocalImageProvider key,
    ImageDecoderCallback decode,
  ) {
    final owner = _CodecOwner();
    final codec = owner.load(() async {
      final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
      return decode(
        buffer,
        getTargetSize:
            width != null ||
                height != null ||
                maxDecodePixels != null ||
                decodeTarget != null
            ? (sourceWidth, sourceHeight) {
                owner.sourceSize = Size(
                  sourceWidth.toDouble(),
                  sourceHeight.toDouble(),
                );
                return _targetSize(sourceWidth, sourceHeight);
              }
            : null,
      );
    });
    return _ImageCompleter(
      owner,
      codec: codec.catchError((Object error, StackTrace stack) {
        if (error is! _ImageDecodeCancelled) {
          scheduleMicrotask(
            () => PaintingBinding.instance.imageCache.evict(this),
          );
        }
        Error.throwWithStackTrace(error, stack);
      }),
      scale: scale,
      debugLabel: file.path,
    );
  }

  ui.TargetImageSize _targetSize(int sourceWidth, int sourceHeight) =>
      decodeTarget?.targetSize(
        sourceWidth,
        sourceHeight,
        maximumPixels: maxDecodePixels,
      ) ??
      _frameTargetSize(
        sourceWidth,
        sourceHeight,
        width: width,
        height: height,
        maxDecodePixels: maxDecodePixels,
      );

  @override
  bool operator ==(Object other) =>
      other is LocalImageProvider &&
      file.path == other.file.path &&
      width == other.width &&
      height == other.height &&
      maxDecodePixels == other.maxDecodePixels &&
      scale == other.scale &&
      decodeTarget == other.decodeTarget;
  @override
  int get hashCode => Object.hash(
    file.path,
    width,
    height,
    maxDecodePixels,
    scale,
    decodeTarget,
  );
}

ImageWork<ui.Image> loadImageFrame(
  File file, {
  ImageDecoderCallback? decode,
  int? width,
  int? height,
  int? maxDecodePixels,
  ImageResources? resources,
  Object? owner,
  bool Function()? isCurrent,
}) => (resources ?? ImageResources.shared).schedule(
  () async {
    if (isCurrent?.call() == false) throw const _ImageDecodeCancelled();
    final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    if (isCurrent?.call() == false) {
      buffer.dispose();
      throw const _ImageDecodeCancelled();
    }
    final codec = await (decode ?? ui.instantiateImageCodecWithSize)(
      buffer,
      getTargetSize: width != null || height != null || maxDecodePixels != null
          ? (sourceWidth, sourceHeight) => _frameTargetSize(
              sourceWidth,
              sourceHeight,
              width: width,
              height: height,
              maxDecodePixels: maxDecodePixels,
            )
          : null,
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  },
  dispose: (image) => image.dispose(),
  owner: owner,
);

ui.TargetImageSize _frameTargetSize(
  int sourceWidth,
  int sourceHeight, {
  int? width,
  int? height,
  int? maxDecodePixels,
}) {
  var ratio = 1.0;
  if (width != null) ratio = math.min(ratio, width / sourceWidth);
  if (height != null) ratio = math.min(ratio, height / sourceHeight);
  if (maxDecodePixels != null) {
    ratio = math.min(
      ratio,
      math.sqrt(maxDecodePixels / (sourceWidth * sourceHeight)),
    );
  }
  return ui.TargetImageSize(
    width: math.max(1, (sourceWidth * ratio).floor()),
    height: math.max(1, (sourceHeight * ratio).floor()),
  );
}

Future<ui.Image?> loadNetworkImageFrame(
  String url, {
  BaseCacheManager? cacheManager,
  ImageDecoderCallback? decode,
  int? width,
  int? height,
  int? maxDecodePixels,
  Object? owner,
  bool Function()? isCurrent,
}) async {
  final file = await CachedImageProvider(
    url,
    cacheManager: cacheManager,
  )._getFile();
  if (isCurrent?.call() == false) return null;
  try {
    return await loadImageFrame(
      file,
      decode: decode,
      width: width,
      height: height,
      maxDecodePixels: maxDecodePixels,
      owner: owner,
      isCurrent: isCurrent,
    ).result;
  } on _ImageDecodeCancelled {
    return null;
  }
}

/// 滚动或刷新可能早于文件读取完成；缓存和监听者都退出后，迟到的 codec
/// 也必须释放。只移除监听时不能释放仍被 ImageCache 保活的动图。
abstract interface class ImageSourceMetadata {
  Size? get sourceSize;
}

class _ImageCompleter extends ImageStreamCompleter
    implements ImageSourceMetadata {
  _ImageCompleter(
    this._owner, {
    required Future<ui.Codec> codec,
    required this.scale,
    required String debugLabel,
  }) {
    this.debugLabel = debugLabel;
    codec.then((value) {
      if (_released) {
        value.dispose();
        return;
      }
      _codec = value;
      _animated = value.frameCount > 1;
      _resume();
    }, onError: _reportDecodeError);
  }

  final _CodecOwner _owner;
  @override
  Size? get sourceSize => _owner.sourceSize;
  final double scale;
  ui.Codec? _codec;
  ui.FrameInfo? _nextFrame;
  Timer? _timer;
  int? _frameCallback;
  Duration? _shownTimestamp;
  Duration? _frameDuration;
  int _framesEmitted = 0;
  bool _decoding = false;
  bool _emitting = false;
  bool _released = false;
  int _handles = 0;
  bool _hadListener = false;
  bool _animated = false;
  final _onIdle = <VoidCallback>{};
  final _onRelease = <VoidCallback>{};

  void _resume() {
    if (!hasListeners || _released || _emitting) return;
    // 恢复监听时复用待显示帧或在途请求，避免迟到结果覆盖下一帧。
    if (_nextFrame != null) {
      _scheduleFrame();
    } else if (_codec != null && !_decoding) {
      unawaited(_decodeNextFrame());
    }
  }

  Future<void> _decodeNextFrame() async {
    _decoding = true;
    try {
      final frame = await _codec!.getNextFrame();
      if (_released) {
        frame.image.dispose();
        return;
      }
      _nextFrame = frame;
      if (_codec!.frameCount == 1) {
        if (hasListeners) _emitFrame();
      } else if (hasListeners) {
        _scheduleFrame();
      }
    } catch (error, stack) {
      _reportDecodeError(error, stack);
    } finally {
      _decoding = false;
    }
  }

  void _reportDecodeError(Object error, StackTrace stack) {
    reportError(
      context: ErrorDescription('resolving an image frame'),
      exception: error,
      stack: stack,
      silent: true,
    );
  }

  void _scheduleFrame() {
    if (_frameCallback != null || _timer != null) return;
    _frameCallback = SchedulerBinding.instance.scheduleFrameCallback((
      timestamp,
    ) {
      _frameCallback = null;
      if (!hasListeners || _released || _nextFrame == null) return;
      final remaining = _shownTimestamp == null
          ? Duration.zero
          : _frameDuration! - (timestamp - _shownTimestamp!);
      if (remaining > Duration.zero) {
        _timer = Timer(remaining * timeDilation, () {
          _timer = null;
          _scheduleFrame();
        });
        return;
      }
      _shownTimestamp = timestamp;
      _emitFrame();
      _resume();
    });
  }

  void _emitFrame() {
    final frame = _nextFrame!;
    _nextFrame = null;
    _frameDuration = frame.duration;
    _framesEmitted++;
    _emitting = true;
    try {
      setImage(
        ImageInfo(
          image: frame.image.clone(),
          scale: scale,
          debugLabel: debugLabel,
        ),
      );
    } finally {
      _emitting = false;
      frame.image.dispose();
    }
    final codec = _codec;
    if (codec != null &&
        (codec.frameCount == 1 ||
            (codec.repetitionCount != -1 &&
                _framesEmitted ~/ codec.frameCount > codec.repetitionCount))) {
      codec.dispose();
      _codec = null;
    }
  }

  @override
  void addListener(ImageStreamListener listener) {
    _hadListener = true;
    _owner.hasListeners = true;
    super.addListener(listener);
    _resume();
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    _owner.hasListeners = hasListeners;
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
      if (_frameCallback case final callback?) {
        SchedulerBinding.instance.cancelFrameCallbackWithId(callback);
        _frameCallback = null;
      }
      _owner.releaseIdleAdmission();
      for (final callback in _onIdle.toList()) {
        callback();
      }
    }
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

  @override
  void reportError({
    DiagnosticsNode? context,
    required Object exception,
    StackTrace? stack,
    InformationCollector? informationCollector,
    bool silent = false,
  }) {
    // 排队期间退出的图片没有帧可交付，取消属于正常生命周期结束。
    if (exception is _ImageDecodeCancelled) return;
    super.reportError(
      context: context,
      exception: exception,
      stack: stack,
      informationCollector: informationCollector,
      silent: silent,
    );
  }

  void _releaseIfUnused() {
    if (_released || !_hadListener || hasListeners || _handles != 0) return;
    _released = true;
    _nextFrame?.image.dispose();
    _nextFrame = null;
    _owner.dispose();
    _codec = null;
    for (final callback in _onRelease.toList()) {
      callback();
    }
    _onIdle.clear();
    _onRelease.clear();
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
  final _resources = ImageResources.shared;
  Size? sourceSize;
  _ThrottledCodec? _codec;
  _DecodeAdmission? _admission;
  bool _disposed = false;
  bool hasListeners = false;

  Future<ui.Codec> load(Future<ui.Codec> Function() create) async {
    if (_disposed) throw const _ImageDecodeCancelled();
    final admission = _admission = _DecodeAdmission(_resources.admit());
    try {
      await admission.ready;
      if (_disposed || admission.cancelled) throw const _ImageDecodeCancelled();
      final codec = await create();
      final managed = _codec = _ThrottledCodec(codec, admission, _resources);
      if (_disposed || admission.cancelled) {
        managed.dispose();
        throw const _ImageDecodeCancelled();
      }
      // 暂停的保活流可能暂不请求首帧，先归还名额，避免阻塞其他图片。
      if (!hasListeners) managed.releaseIdleAdmission();
      return managed;
    } catch (_) {
      admission.release();
      rethrow;
    } finally {
      _admission = null;
    }
  }

  void dispose() {
    _disposed = true;
    _admission?.cancel();
    _codec?.dispose();
    _codec = null;
  }

  void releaseIdleAdmission() => _codec?.releaseIdleAdmission();
}

/// 延续原组件的动图帧率限制，避免短帧 GIF 持续占用 CPU。
class _ThrottledCodec implements ui.Codec {
  _ThrottledCodec(this._codec, this._decodeAdmission, this._resources) {
    Diagnostics.instance.gauge('imageCodecs', ++_activeCodecs);
  }

  static int _activeCodecs = 0;

  final ui.Codec _codec;
  final ImageResources _resources;
  bool _disposed = false;
  bool _nativeDisposed = false;
  bool _firstFrame = true;
  bool _decoding = false;
  _FrameAdmission? _admission;
  _DecodeAdmission? _decodeAdmission;

  @override
  int get frameCount => _codec.frameCount;

  @override
  int get repetitionCount => _codec.repetitionCount;

  void releaseIdleAdmission() {
    if (_decoding) return;
    _decodeAdmission?.release();
    _decodeAdmission = null;
  }

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    _decoding = true;
    final admission = _decodeAdmission ??= _DecodeAdmission(_resources.admit());
    TraceOperation? operation;
    try {
      await admission.ready;
      if (_disposed || admission.cancelled) {
        if (admission.cancelled) dispose();
        throw const _ImageDecodeCancelled();
      }
      operation = Diagnostics.instance.begin('imageFrame', '解码图片帧');
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
      if (_disposed || admission.cancelled) {
        frame.image.dispose();
        if (admission.cancelled) dispose();
        throw const _ImageDecodeCancelled();
      }
      return frameCount > 1 &&
              frame.duration < const Duration(milliseconds: 100)
          ? _SlowFrame(frame.image)
          : frame;
    } catch (error) {
      operation?.finish(error: error);
      rethrow;
    } finally {
      _decoding = false;
      admission.release();
      _decodeAdmission = null;
      operation?.finish();
      if (_disposed) _disposeNativeCodec();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_decoding) {
      _decodeAdmission?.cancel();
    } else {
      _decodeAdmission?.release();
    }
    _admission?.cancel();
    _admission = null;
    // 原生 dispose 可能丢弃在途回调；等待取帧结束后再销毁，确保名额归还。
    if (!_decoding) _disposeNativeCodec();
  }

  void _disposeNativeCodec() {
    if (_nativeDisposed) return;
    _nativeDisposed = true;
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
    this.decodeTarget,
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
  final ImageDecodeTarget? decodeTarget;
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
  Widget build(BuildContext context) {
    // 隐藏页面保留业务状态，缩略图交还 LRU；恢复时只加载活动页面。
    if (!ImageLoadingScope.isEnabled(context)) {
      return SizedBox(width: width, height: height);
    }
    return Image(
      image: CachedImageProvider(
        imageUrl,
        cacheManager: cacheManager,
        width: decodeTarget == null ? memCacheWidth : null,
        height: decodeTarget == null ? memCacheHeight : null,
        maxDecodePixels: maxDecodePixels,
        decodeTarget: decodeTarget,
      ),
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      filterQuality: filterQuality,
      color: color,
      colorBlendMode: colorBlendMode,
      errorBuilder: errorBuilder ?? (context, _, _) => _placeholder(context),
      frameBuilder: (context, child, frame, synchronouslyLoaded) =>
          _ImageFadeIn(
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
  }

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

/// 从文件映射、codec 创建到首帧交付共用名额，避免队列持有整批原生解码器。
class _DecodeAdmission {
  _DecodeAdmission(this._permit);
  final ImageDecodePermit _permit;
  Future<void> get ready => _permit.ready;
  bool get cancelled => _permit.cancelled;
  void cancel() => _permit.cancel();
  void release() => _permit.release();
}

class _ImageDecodeCancelled implements Exception {
  const _ImageDecodeCancelled();
}
