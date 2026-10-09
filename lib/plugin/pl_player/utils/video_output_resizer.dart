import 'dart:async';

import 'package:pili_aurora/plugin/pl_player/utils/video_output_size.dart';

/// 合并视口请求，并串行提交纹理尺寸；请求目标与已提交尺寸分别保存。
///
/// 暂停只停止新提交，不撤销已进入原生通道的提交。SurfaceTexture 一旦
/// 改变尺寸，同一 Surface 的 mpv 也必须同步，不能用更新的视口废弃半次提交。
class VideoOutputResizer {
  VideoOutputResizer({
    required this._apply,
    required this._onError,
    this._enabled = true,
    this._settleDelay = const Duration(milliseconds: 250),
  });

  final Future<bool> Function(VideoOutputSize size, bool Function() isCurrent)
  _apply;
  final void Function(VideoOutputSize size, Object error, StackTrace stackTrace)
  _onError;
  // 等几何稳定后提交；这不是周期轮询。Windows 调用方保留原 100ms。
  final Duration _settleDelay;

  Timer? _timer;
  VideoOutputSize? _target;
  VideoOutputSize? _applied;
  bool _enabled;
  bool _applying = false;
  bool _ready = false;
  bool _disposed = false;
  int _generation = 0;

  VideoOutputSize? get target => _target;
  VideoOutputSize? get applied => _applied;
  int get generation => _generation;
  bool get pending => _applying || (_target != null && _target != _applied);

  /// 布局仍变化时推迟尚未开始的提交，即使目标四舍五入后尺寸相同。
  /// 正在执行的原生提交仍必须完成，不取消半次 buffer / mpv 更新。
  void defer() {
    if (!_disposed && pending) _schedule();
  }

  void request(VideoOutputSize size) {
    if (_disposed) return;
    if (_target == size && (_timer != null || _applying || _applied == size)) {
      return;
    }
    _target = size;
    _schedule();
  }

  void setEnabled(bool enabled) {
    if (_disposed || _enabled == enabled) return;
    _enabled = enabled;
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    _ready = false;
    // A 已提交、B 提交中、目标又回到 A 时，仍需排队恢复 A。
    if (!_enabled || _target == null || (!_applying && _target == _applied)) {
      return;
    }
    _timer = Timer(_settleDelay, () {
      _timer = null;
      _ready = true;
      unawaited(_drain());
    });
  }

  Future<void> _drain() async {
    if (_applying || !_ready || !_enabled || _disposed) return;
    _ready = false;
    final size = _target;
    if (size == null || size == _applied) return;
    final generation = _generation;
    bool isCurrent() => !_disposed && generation == _generation;
    _applying = true;
    try {
      final accepted = await _apply(size, isCurrent);
      if (isCurrent()) _applied = accepted ? size : null;
    } catch (error, stackTrace) {
      if (isCurrent()) {
        // 失败可能发生在 buffer 已改变之后，旧的成功尺寸不再足以去重。
        _applied = null;
        _onError(size, error, stackTrace);
      }
    } finally {
      _applying = false;
      // 通道等待期间可能已有更新的目标；只提交最后一次有效请求。
      if (_ready) unawaited(_drain());
    }
  }

  /// 源视频重建了纹理，旧的提交缓存不能用于新 Surface，即使尺寸相同。
  void invalidate() {
    if (_disposed) return;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _ready = false;
    _target = null;
    _applied = null;
  }

  void dispose() {
    invalidate();
    _disposed = true;
  }
}
