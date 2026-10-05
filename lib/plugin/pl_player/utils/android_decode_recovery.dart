import 'dart:async';

/// 处理不会进入 media_kit stream.error 的 Android 视频输出错误。
/// 只改变 hwdec（mpv 会重新初始化解码器），不重开媒体或覆盖播放/暂停状态。
class AndroidDecodeRecovery {
  AndroidDecodeRecovery({
    required this.activeDecoder,
    required this.applyDecoder,
    required this.onError,
  });

  final String? Function() activeDecoder;
  final void Function(String decoder) applyDecoder;
  final void Function(Object error) onError;
  Timer? _pending;
  bool _disposed = false;
  bool _softwareAttempted = false;
  bool _copyAttempted = false;

  void onLog({
    required String prefix,
    required String level,
    required String message,
  }) {
    if (_disposed || _pending != null || _softwareAttempted) return;
    if (level != 'error' && level != 'fatal') return;
    final text = message.toLowerCase();
    final surfaceFailure =
        prefix == 'ffmpeg/video' &&
        text.contains('mediacodec') &&
        text.contains('both surface and native_window are null');
    final imageFailure =
        prefix == 'vo/gpu/aimagereader' &&
        text.contains('acquirelatestimage failed');
    if (!surfaceFailure && !imageFailure) return;

    // 合并同一轮初始化产生的成批错误，等 mpv 自身的候选探测结束再判断。
    _pending = Timer(const Duration(milliseconds: 200), () {
      _pending = null;
      if (_disposed) return;
      try {
        final decoder = activeDecoder()?.trim();
        if (decoder != 'mediacodec' && decoder != 'mediacodec-copy') return;
        final next = decoder == 'mediacodec' && !_copyAttempted
            ? 'mediacodec-copy'
            : 'no';
        _copyAttempted = true;
        // copy 仍失败时只尝试一次软解，避免日志触发无限切换。
        _softwareAttempted = next == 'no';
        applyDecoder(next);
      } catch (error) {
        _softwareAttempted = true;
        onError(error);
      }
    });
  }

  void reset() {
    _pending?.cancel();
    _pending = null;
    _softwareAttempted = false;
    _copyAttempted = false;
  }

  void dispose() {
    reset();
    _disposed = true;
  }
}
