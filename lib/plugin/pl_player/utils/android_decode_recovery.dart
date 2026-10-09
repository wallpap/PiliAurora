import 'dart:async';

/// 处理不会进入 media_kit stream.error 的 Android 视频输出错误。
/// 硬解失败时只改变 hwdec；软解持续解析失败时允许一次保留播放状态的重载。
class AndroidDecodeRecovery {
  AndroidDecodeRecovery({
    required this.activeDecoder,
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

  final String? Function() activeDecoder;
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
    if (_pending != null || _softwareAttempted) return;
    final surfaceFailure =
        prefix == 'ffmpeg/video' &&
        text.contains('mediacodec') &&
        text.contains('both surface and native_window are null');
    final imageFailure =
        prefix == 'vo/gpu/aimagereader' &&
        text.contains('acquirelatestimage failed');
    if (!surfaceFailure && !imageFailure) return;
    _record('decoder.recovery.scheduled', {
      'reason': surfaceFailure
          ? 'mediacodec-null-surface'
          : 'aimagereader-acquire-failed',
      'prefix': prefix,
      'nativeLevel': level,
      'trigger': message,
      'delayMs': 200,
    });

    // 合并同一轮初始化产生的成批错误，等 mpv 自身的候选探测结束再判断。
    _pending = Timer(const Duration(milliseconds: 200), () {
      _pending = null;
      if (_disposed) return;
      try {
        final decoder = activeDecoder()?.trim();
        if (decoder != 'mediacodec' && decoder != 'mediacodec-copy') {
          _record('decoder.recovery.skipped', {
            'activeDecoder': decoder,
            'reason': 'native-already-recovered',
          });
          return;
        }
        final next = decoder == 'mediacodec' && !_copyAttempted
            ? 'mediacodec-copy'
            : 'no';
        _copyAttempted = true;
        // copy 仍失败时只尝试一次软解，避免日志触发无限切换。
        _softwareAttempted = next == 'no';
        _record('decoder.recovery.apply', {'from': decoder, 'to': next});
        applyDecoder(next);
        _notifyFallback(next);
      } catch (error) {
        _softwareAttempted = true;
        onError(error);
      }
    });
  }

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
      if (activeDecoder()?.trim() != 'no') return;
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
        if (activeDecoder()?.trim() != 'no') return;
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
  }

  void dispose() {
    reset();
    _disposed = true;
  }
}
