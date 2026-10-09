import 'dart:async';

typedef AndroidDecodeState = ({
  String? decoder,
  bool playing,
  bool buffering,
  bool seeking,
  bool completed,
  bool eof,
  double? videoPts,
});

/// 处理不会进入 media_kit stream.error 的 Android 视频输出错误。
/// 硬解失败时只改变 hwdec；软解持续解析失败时允许一次保留播放状态的重载。
class AndroidDecodeRecovery {
  AndroidDecodeRecovery({
    required this.readState,
    required this.applyDecoder,
    required this.onError,
    this.recoverSoftware,
    this.onFallback,
    this.onDiagnostic,
  });

  final void Function(String action, Map<String, Object?> details)?
  onDiagnostic;
  void _record(String action, [Map<String, Object?> details = const {}]) {
    try {
      onDiagnostic?.call(action, {
        'recoveryGeneration': _generation,
        'copyAttempted': _copyAttempted,
        'softwareAttempted': _softwareAttempted,
        'softwareReloadAttempted': _softwareReloadAttempted,
        'parseErrors': _parseErrors,
        ...details,
      });
    } catch (_) {
      /* Diagnostic observers cannot alter fallback behavior. */
    }
  }

  /// 媒体卸载或播放器销毁时返回 null；暂停媒体仍保留状态。
  final AndroidDecodeState? Function() readState;
  final void Function(String decoder) applyDecoder;
  final void Function(Object error) onError;
  final void Function(String decoder)? onFallback;

  /// 返回是否实际执行了重载；加载忙时可拒绝且不消耗本媒体的预算。
  final Future<bool> Function()? recoverSoftware;
  Timer? _pending;
  Timer? _softwarePending;
  int _generation = 0;
  bool _disposed = false;
  bool _softwareAttempted = false;
  bool _copyAttempted = false;
  bool _fallbackNotified = false;
  bool _softwareReloadAttempted = false;
  int _parseErrors = 0;
  int _imageErrors = 0;

  void onLog({
    required String prefix,
    required String level,
    required String message,
  }) {
    if (_disposed) return;
    if (level != 'error' && level != 'fatal') return;
    final text = message.toLowerCase();
    if (prefix == 'ffmpeg/video' &&
        text.contains('libdav1d: error parsing obu data')) {
      _onSoftwareParseError();
      return;
    }
    if (_softwareAttempted) return;
    final surfaceFailure =
        prefix == 'ffmpeg/video' &&
        text.contains('mediacodec') &&
        text.contains('both surface and native_window are null');
    final imageFailure =
        prefix == 'vo/gpu/aimagereader' &&
        text.contains('acquirelatestimage failed');
    final decoderFailure =
        prefix == 'ffmpeg/video' &&
        text.contains('mediacodec') &&
        const [
          'failed to configure codec',
          'failed to start codec',
          'failed to get output buffer',
          'failed to dequeue output buffer',
        ].any(text.contains);
    if (!surfaceFailure && !imageFailure && !decoderFailure) return;
    final emptyImage =
        imageFailure &&
        RegExp(r'acquirelatestimage failed:\s*-30001\b').hasMatch(text);
    try {
      final state = readState();
      if (_mediaInactive(state)) return;
      final decoder = state!.decoder?.trim();
      if (_copyMemoryOutput(decoder, surfaceFailure, imageFailure)) return;
      if (emptyImage && !_canObserveFrames(state)) {
        if (_imageErrors > 0) {
          _pending?.cancel();
          _pending = null;
          _imageErrors = 0;
        }
        _record('decoder.recovery.skipped', {'reason': 'waiting-for-video'});
        return;
      }
      if (_pending != null) {
        if (!emptyImage && _imageErrors > 0) {
          // 明确的解码失败优先处理，避免被空队列观察窗口合并掉。
          _pending!.cancel();
          _pending = null;
        } else {
          if (emptyImage && _imageErrors > 0) _imageErrors++;
          return;
        }
      }
      _imageErrors = emptyImage ? 1 : 0;
      final initialDecoder = decoder;
      final videoPts = state.videoPts;
      final delay = Duration(milliseconds: emptyImage ? 500 : 200);
      _record('decoder.recovery.scheduled', {
        'reason': surfaceFailure
            ? 'mediacodec-null-surface'
            : imageFailure
            ? 'aimagereader-acquire-failed'
            : 'mediacodec-decoder-failed',
        'prefix': prefix,
        'nativeLevel': level,
        'trigger': message,
        'delayMs': delay.inMilliseconds,
        if (emptyImage) 'videoPts': videoPts,
      });

      // 空队列需同时满足连续错误与视频停滞；seek、暂停和等待数据不消耗预算。
      _pending = Timer(delay, () {
        _pending = null;
        final imageErrors = _imageErrors;
        _imageErrors = 0;
        if (_disposed) return;
        try {
          final state = readState();
          if (_mediaInactive(state)) return;
          final decoder = state!.decoder?.trim();
          if (_copyMemoryOutput(decoder, surfaceFailure, imageFailure)) return;
          if (decoder != initialDecoder) {
            _record('decoder.recovery.skipped', {
              'reason': 'output-backend-changed',
              'previousDecoder': initialDecoder,
              'activeDecoder': decoder,
            });
            return;
          }
          if (emptyImage &&
              (imageErrors < 3 ||
                  !_canObserveFrames(state) ||
                  state.videoPts != videoPts)) {
            _record('decoder.recovery.skipped', {
              'reason': 'image-result-transient',
              'imageErrors': imageErrors,
              'previousVideoPts': videoPts,
              'videoPts': state.videoPts,
            });
            return;
          }
          if (decoder != 'mediacodec' && decoder != 'mediacodec-copy') {
            _record('decoder.recovery.skipped', {
              'activeDecoder': decoder,
              'reason': decoder == null || decoder.isEmpty
                  ? 'decoder-unavailable'
                  : 'native-already-recovered',
            });
            return;
          }
          final next = decoder == 'mediacodec' && !_copyAttempted
              ? 'mediacodec-copy'
              : 'no';
          _copyAttempted = true;
          _softwareAttempted = next == 'no';
          _record('decoder.recovery.apply', {'from': decoder, 'to': next});
          applyDecoder(next);
          _notifyFallback(next);
        } catch (error) {
          _softwareAttempted = true;
          onError(error);
        }
      });
    } catch (error) {
      _softwareAttempted = true;
      onError(error);
    }
  }

  bool _mediaInactive(AndroidDecodeState? state) {
    if (state != null && !state.completed && !state.eof) return false;
    _record('decoder.recovery.skipped', {
      'reason': state == null ? 'media-unavailable' : 'media-finished',
    });
    return true;
  }

  bool _copyMemoryOutput(String? decoder, bool surface, bool image) {
    if (decoder != 'mediacodec-copy' || (!surface && !image)) return false;
    // copy 从普通缓冲区取图像，Surface 可以为空；ImageReader 属于旧的直接输出路径。
    _record('decoder.recovery.skipped', {
      'reason': surface ? 'copy-memory-output' : 'output-backend-changed',
    });
    return true;
  }

  bool _canObserveFrames(AndroidDecodeState state) =>
      state.playing &&
      !state.buffering &&
      !state.seeking &&
      state.videoPts != null &&
      state.videoPts!.isFinite;

  void _notifyFallback(String decoder) {
    if (_fallbackNotified) return;
    // 同一媒体的 copy → 软解链只提示一次，提示异常不能中断解码恢复。
    _fallbackNotified = true;
    try {
      onFallback?.call(decoder);
    } catch (error) {
      onError(error);
    }
  }

  void _onSoftwareParseError() {
    if (recoverSoftware == null || _softwareReloadAttempted) return;
    try {
      final state = readState();
      if (_mediaInactive(state) || state?.decoder?.trim() != 'no') return;
    } catch (error) {
      _softwareReloadAttempted = true;
      onError(error);
      return;
    }
    _parseErrors++;
    _record('decoder.software.parse-error');
    if (_softwarePending != null) return;
    final generation = _generation;
    // 单个坏帧由解码器自行跳过；只有短时间内持续解析失败才重建媒体。
    _softwarePending = Timer(const Duration(milliseconds: 200), () async {
      _softwarePending = null;
      final persistent = _parseErrors >= 3;
      _parseErrors = 0;
      if (_disposed || !persistent || _softwareReloadAttempted) return;
      try {
        final state = readState();
        if (_mediaInactive(state) || state?.decoder?.trim() != 'no') return;
        // 先消耗预算，重载过程中出现同样错误也不能形成重开循环。
        _softwareReloadAttempted = true;
        _record('decoder.software.reload.begin');
        final reloaded = await recoverSoftware!();
        _record('decoder.software.reload.end', {'accepted': reloaded});
        if (!reloaded && !_disposed && generation == _generation) {
          _softwareReloadAttempted = false;
        }
      } catch (error) {
        // 上一次媒体迟到的失败不能耗尽新媒体的恢复预算。
        if (!_disposed && generation == _generation) onError(error);
      }
    });
  }

  void reset() {
    _record('decoder.recovery.reset');
    _generation++;
    _softwarePending?.cancel();
    _softwarePending = null;
    _pending?.cancel();
    _pending = null;
    _softwareAttempted = false;
    _copyAttempted = false;
    _fallbackNotified = false;
    _softwareReloadAttempted = false;
    _parseErrors = 0;
    _imageErrors = 0;
  }

  void dispose() {
    reset();
    _disposed = true;
  }
}
