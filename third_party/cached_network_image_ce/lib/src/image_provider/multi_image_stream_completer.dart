import 'dart:async';
import 'dart:ui' as ui show Codec, FrameInfo;

import 'package:cached_network_image_ce/src/gif_frame_duration.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

/// Slows down animations by this factor to help in development.
double get timeDilation => _timeDilation;
double _timeDilation = 1;

/// An ImageStreamCompleter with support for loading multiple images.
class MultiImageStreamCompleter extends ImageStreamCompleter {
  /// The constructor to create an MultiImageStreamCompleter. The [codec]
  /// should be a stream with the images that should be shown. The
  /// [chunkEvents] should indicate the [ImageChunkEvent]s of the first image
  /// to show.
  MultiImageStreamCompleter({
    required Stream<ui.Codec> codec,
    required double scale,
    Stream<ImageChunkEvent>? chunkEvents,
    InformationCollector? informationCollector,
    this.minimumGifFrameDuration = const Duration(milliseconds: 100),
  })  : _informationCollector = informationCollector,
        _scale = scale {
    codec.listen(
      (event) {
        if (__disposed) {
          event.dispose();
          return;
        }
        if (_timer != null) {
          _nextImageCodec?.dispose();
          _nextImageCodec = event;
        } else {
          _handleCodecReady(event);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (__disposed) return;
        reportError(
          context: ErrorDescription('resolving an image codec'),
          exception: error,
          stack: stack,
          informationCollector: informationCollector,
          silent: true,
        );
      },
    );
    if (chunkEvents != null) {
      _chunkSubscription = chunkEvents.listen(
        reportImageChunkEvent,
        onError: (Object error, StackTrace stack) {
          reportError(
            context: ErrorDescription('loading an image'),
            exception: error,
            stack: stack,
            informationCollector: informationCollector,
            silent: true,
          );
        },
      );
    }
  }

  ui.Codec? _codec;
  ui.Codec? _nextImageCodec;
  ui.Codec? _decodingCodec;
  final _retiredCodecs = Set<ui.Codec>.identity();
  final double _scale;
  final InformationCollector? _informationCollector;

  /// The minimum frame duration applied to GIF images when decoded frame
  /// durations are extremely short.
  ///
  /// Defaults to 100ms.
  final Duration minimumGifFrameDuration;
  ui.FrameInfo? _nextFrame;

  // When the current was first shown.
  Duration? _shownTimestamp;

  // The requested duration for the current frame;
  Duration? _frameDuration;

  // How many frames have been emitted so far.
  int _framesEmitted = 0;
  Timer? _timer;
  StreamSubscription<ImageChunkEvent>? _chunkSubscription;

  // Used to guard against registering multiple _handleAppFrame callbacks for the same frame.
  bool _frameCallbackScheduled = false;

  /// We must avoid disposing a completer if it never had a listener, even
  /// if all [keepAlive] handles get disposed.
  bool __hadAtLeastOneListener = false;

  bool __disposed = false;

  void _switchToNewCodec() {
    _timer = null;
    final codec = _nextImageCodec!;
    _nextImageCodec = null;
    _handleCodecReady(codec);
  }

  void _handleCodecReady(ui.Codec codec) {
    if (_codec case final previous?) _retireCodec(previous);
    _nextFrame?.image.dispose();
    _nextFrame = null;
    _codec = codec;
    _framesEmitted = 0;
    _shownTimestamp = null;
    _frameDuration = null;

    if (hasListeners) {
      _decodeNextFrameAndSchedule();
    }
  }

  void _handleAppFrame(Duration timestamp) {
    _frameCallbackScheduled = false;
    if (__disposed || !hasListeners || _nextFrame == null || _codec == null) {
      return;
    }
    if (_isFirstFrame() || _hasFrameDurationPassed(timestamp)) {
      final codec = _codec!;
      final frame = _nextFrame!;
      _nextFrame = null;
      _emitFrame(ImageInfo(image: frame.image, scale: _scale));
      if (__disposed || !identical(codec, _codec)) return;
      _shownTimestamp = timestamp;
      _frameDuration = clampGifFrameDuration(
        frame.duration,
        minimumGifFrameDuration: minimumGifFrameDuration,
      );
      if (_framesEmitted % _codec!.frameCount == 0 && _nextImageCodec != null) {
        _switchToNewCodec();
      } else {
        final completedCycles = _framesEmitted ~/ _codec!.frameCount;
        if (_codec!.repetitionCount == -1 ||
            completedCycles <= _codec!.repetitionCount) {
          _decodeNextFrameAndSchedule();
        } else {
          _retireCodec(_codec!);
          _codec = null;
        }
      }
      return;
    }
    final delay = _frameDuration! - (timestamp - _shownTimestamp!);
    _timer = Timer(delay * timeDilation, _scheduleAppFrame);
  }

  bool _isFirstFrame() {
    return _frameDuration == null;
  }

  bool _hasFrameDurationPassed(Duration timestamp) {
    return timestamp - _shownTimestamp! >= _frameDuration!;
  }

  Future<void> _decodeNextFrameAndSchedule() async {
    final codec = _codec;
    if (__disposed || codec == null || _decodingCodec != null) return;
    _decodingCodec = codec;
    try {
      final frame = await codec.getNextFrame();
      if (__disposed || !identical(codec, _codec)) {
        frame.image.dispose();
        return;
      }
      _nextFrame = frame;
      if (codec.frameCount == 1) {
        if (hasListeners) {
          // setImage接管此帧；不能继续在_nextFrame中保留同一个句柄。
          _nextFrame = null;
          _emitFrame(ImageInfo(image: frame.image, scale: _scale));
          if (identical(codec, _codec)) {
            _codec = null;
            _retireCodec(codec);
          }
        }
      } else if (hasListeners) {
        _scheduleAppFrame();
      }
    } on Object catch (exception, stack) {
      if (__disposed || !identical(codec, _codec)) return;
      reportError(
        context: ErrorDescription('resolving an image frame'),
        exception: exception,
        stack: stack,
        informationCollector: _informationCollector,
        silent: true,
      );
    } finally {
      _decodingCodec = null;
      if (_retiredCodecs.remove(codec)) codec.dispose();
      if (!__disposed && !identical(codec, _codec) && hasListeners) {
        _decodeNextFrameAndSchedule();
      }
    }
  }

  void _retireCodec(ui.Codec codec) {
    // 原生dispose可能丢弃在途回调，待回执归还FrameInfo后再销毁codec。
    if (identical(codec, _decodingCodec)) {
      _retiredCodecs.add(codec);
    } else {
      codec.dispose();
    }
  }

  void _scheduleAppFrame() {
    _timer = null;
    if (__disposed || _frameCallbackScheduled) {
      return;
    }
    _frameCallbackScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback(_handleAppFrame);
  }

  void _emitFrame(ImageInfo imageInfo) {
    setImage(imageInfo);
    _framesEmitted += 1;
  }

  @override
  void addListener(ImageStreamListener listener) {
    __hadAtLeastOneListener = true;
    final resume = !hasListeners;
    super.addListener(listener);
    if (resume && _nextFrame != null && _codec?.frameCount == 1) {
      final frame = _nextFrame!;
      _nextFrame = null;
      final codec = _codec!;
      _emitFrame(ImageInfo(image: frame.image, scale: _scale));
      if (identical(codec, _codec)) {
        _codec = null;
        _retireCodec(codec);
      }
    } else if (resume && _nextFrame != null) {
      _scheduleAppFrame();
    } else if (resume && _codec != null) {
      _decodeNextFrameAndSchedule();
    }
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
      __maybeDispose();
    }
  }

  int __keepAliveHandles = 0;

  @override
  ImageStreamCompleterHandle keepAlive() {
    final delegateHandle = super.keepAlive();
    return _MultiImageStreamCompleterHandle(this, delegateHandle);
  }

  void __maybeDispose() {
    if (!__hadAtLeastOneListener ||
        __disposed ||
        hasListeners ||
        __keepAliveHandles != 0) {
      return;
    }

    __disposed = true;
    _timer?.cancel();
    _timer = null;
    _nextFrame?.image.dispose();
    _nextFrame = null;
    if (_codec case final codec?) _retireCodec(codec);
    _codec = null;
    _nextImageCodec?.dispose();
    _nextImageCodec = null;

    _chunkSubscription?.onData(null);
    _chunkSubscription?.cancel();
    _chunkSubscription = null;
  }
}

class _MultiImageStreamCompleterHandle implements ImageStreamCompleterHandle {
  _MultiImageStreamCompleterHandle(this._completer, this._delegateHandle) {
    _completer!.__keepAliveHandles += 1;
  }

  MultiImageStreamCompleter? _completer;
  final ImageStreamCompleterHandle _delegateHandle;

  /// Call this method to signal the [ImageStreamCompleter] that it can now be
  /// disposed when its last listener drops.
  ///
  /// This method must only be called once per object.
  @override
  void dispose() {
    assert(_completer != null);
    assert(_completer!.__keepAliveHandles > 0);
    assert(!_completer!.__disposed);

    _delegateHandle.dispose();

    _completer!.__keepAliveHandles -= 1;
    _completer!.__maybeDispose();
    _completer = null;
  }
}
