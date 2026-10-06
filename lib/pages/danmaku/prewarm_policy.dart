/// 只调节可丢弃的预热工作，不参与弹幕准入和显示数量决策。
class DanmakuPrewarmPolicy {
  static const windowSize = 32;
  final _accepted = List<bool>.filled(windowSize, false);
  int _cursor = 0;
  int samples = 0;
  int accepted = 0;
  int _backoffUntilMs = 0;

  void recordAdmission(bool value) {
    if (samples == windowSize) {
      if (_accepted[_cursor]) accepted--;
    } else {
      samples++;
    }
    _accepted[_cursor] = value;
    if (value) accepted++;
    _cursor = (_cursor + 1) % windowSize;
  }

  bool allowImages({
    required int pending,
    required int activeBytes,
    required int maxActiveBytes,
    required int nowMs,
  }) =>
      samples >= 8 &&
      accepted * 4 >= samples * 3 &&
      pending <= 16 &&
      activeBytes * 4 < maxActiveBytes * 3 &&
      nowMs >= _backoffUntilMs;

  // 帧耗时是延迟到达的历史信号，只用于保守退避，不能视为当前空闲时间。
  void backoff(int nowMs) => _backoffUntilMs = nowMs + 500;

  void clear() {
    _accepted.fillRange(0, windowSize, false);
    _cursor = samples = accepted = _backoffUntilMs = 0;
  }
}
