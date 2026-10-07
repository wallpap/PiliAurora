import 'dart:async';

/// 以标签共享冷却窗口；首次立即执行，窗口内丢弃重复调用。
abstract final class ActionThrottle {
  static final _timers = <String, Timer>{};

  /// 返回 true 表示本次被抑制。冷却按时间计算，不等待异步动作结束。
  static bool run(String tag, Duration interval, void Function() action) {
    if (_timers.containsKey(tag)) return true;
    // 先登记再执行，阻止动作同步重入；异常也不绕过冷却窗口。
    _timers[tag] = Timer(interval, () => _timers.remove(tag));
    action();
    return false;
  }

  static void cancel(String tag) => _timers.remove(tag)?.cancel();
}

/// 安静期结束后执行最后一次动作；取消仅针对尚未开始的动作。
class Debouncer {
  Debouncer(this.delay);

  final Duration delay;
  Timer? _timer;

  void run(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      action();
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
