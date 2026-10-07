import 'dart:async';

import 'package:pili_aurora/utils/rate_limiter.dart';
import 'package:flutter/widgets.dart';

mixin DebounceStreamMixin<T> {
  Duration get duration => const Duration(milliseconds: 200);
  StreamController<T>? ctr;
  StreamSubscription<T>? _sub;
  late final _debouncer = Debouncer(duration);

  void onValueChanged(T value);

  void subInit() {
    // 允许重新初始化，但不能留下旧订阅或旧防抖任务。
    subDispose();
    _sub = (ctr = StreamController<T>()).stream.listen(
      (value) => _debouncer.run(() => onValueChanged(value)),
    );
  }

  void subDispose() {
    _debouncer.cancel();
    _sub?.cancel();
    ctr?.close();
    _sub = null;
    ctr = null;
  }
}

abstract class DebounceStreamState<T extends StatefulWidget, S> extends State<T>
    with DebounceStreamMixin<S> {
  @override
  void dispose() {
    subDispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    subInit();
  }
}
