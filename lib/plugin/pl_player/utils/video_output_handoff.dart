import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// 用独立快照跨过原生 resize；布局继续由同一个 FittedBox 缩放。
/// 提交结果必须包含 Flutter 已消费提交后帧的确认，不能只是通道返回。
class VideoOutputHandoff extends ChangeNotifier {
  VideoOutputHandoff({
    required this.capture,
    required this.waitForPaint,
    required this.waitForProtectedFrame,
  });

  final Future<ui.Image?> Function() capture;
  final Future<void> Function() waitForPaint;
  // A UI-frame callback is insufficient before changing a live buffer.
  final Future<bool> Function() waitForProtectedFrame;
  ui.Image? _image;
  int _sourceRevision = 0;
  bool _disposed = false;

  ui.Image? get image => _image;

  Future<bool> run({
    required bool Function() isCurrent,
    required bool Function() canStart,
    required Future<bool> Function(bool Function() canStart) submit,
    Future<bool> Function()? recover,
  }) async {
    final source = _sourceRevision;
    bool current() => !_disposed && source == _sourceRevision && isCurrent();
    bool ready() => current() && canStart();
    if (!ready()) return false;

    final snapshot = _image ?? await capture();
    if (snapshot == null) return false; // 无有效保护帧时保留当前输出，不裸 resize。
    if (!ready()) {
      if (!identical(snapshot, _image)) snapshot.dispose();
      return false;
    }
    _image = snapshot;
    notifyListeners();
    await waitForPaint(); // 先把保护图提交到 Flutter 场景。
    if (!ready()) {
      await _clear(snapshot);
      return false;
    }
    final protected = await waitForProtectedFrame();
    if (!protected || !ready()) {
      await _clear(snapshot);
      return false;
    }

    // 错误可能发生在 buffer 已改变之后。保持保护帧，尝试恢复旧几何；
    // 恢复也必须得到消费确认。不能靠 catch/finally 或超时强制撤图。
    final bool accepted;
    try {
      accepted = await submit(ready);
    } catch (_) {
      if (current() && recover != null) {
        try {
          if (await recover() && current()) {
            await waitForPaint();
            if (current()) await _clear(snapshot);
          }
        } catch (_) {
          // 恢复失败仍保留图片；下一次源生命周期事件会清理它。
        }
      }
      rethrow;
    }
    if (!current()) return false;
    if (!accepted) {
      // false 只允许表示提交前拒绝，或已失效源的取消；原生错误必须抛出。
      await _clear(snapshot);
      return false;
    }
    await waitForPaint(); // 消费通知来自 raster 线程，至少再提交一个布局帧。
    if (!current()) return false;
    await _clear(snapshot);
    return current();
  }

  Future<void> _clear(ui.Image snapshot) async {
    if (!identical(_image, snapshot)) return;
    _image = null;
    if (!_disposed) notifyListeners();
    // RawImage 尚可能被前一个 scene 引用；等移除它的布局帧再释放句柄。
    await waitForPaint();
    snapshot.dispose();
  }

  void invalidate() {
    _sourceRevision++;
    final snapshot = _image;
    if (snapshot != null) {
      _image = null;
      if (!_disposed) notifyListeners();
      // ui.Image 的 scene 持有独立引用，释放 Dart 句柄不会释放 scene 的引用。
      snapshot.dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    invalidate();
    super.dispose();
  }
}
