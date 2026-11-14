import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// 自编引擎的只读图形缓存采样；标准引擎返回 unsupported。
class WindowsGraphicsMemoryMetrics {
  WindowsGraphicsMemoryMetrics({this.includeResources = false});

  final bool includeResources;
  static const _channel = MethodChannel(
    'pili_aurora/graphics_memory',
    JSONMethodCodec(),
  );
  Timer? _timer;
  int _generation = 0;
  // 超时不能取消平台请求，直到实际回执前不发下一条（包括重新启动后）。
  Future<Map<String, Object?>?>? _pending;
  final _clock = Stopwatch()..start();
  int? _receivedMs;
  Map<String, Object?> _latest = const {'status': 'disabled'};

  Map<String, Object?> sample() => {
    ..._latest,
    'cacheAgeMs': _receivedMs == null
        ? null
        : _clock.elapsedMilliseconds - _receivedMs!,
  };

  Future<void> start() async {
    if (!Platform.isWindows) return;
    final generation = ++_generation;
    _timer?.cancel();
    _latest = const {'status': 'warmingUp'};
    _receivedMs = null;
    _timer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _read(generation),
    );
    await _read(generation);
  }

  Future<void> _read(int generation) async {
    if (generation != _generation || _pending != null) return;
    final request = _channel.invokeMapMethod<String, Object?>(
      'sample',
      {'resources': includeResources},
    );
    _pending = request;
    // 此分支一直等待真实完成；timeout 分支只更新状态。
    unawaited(
      request.then<void>(
        (_) {
          _pending = null;
        },
        onError: (Object _, StackTrace _) {
          _pending = null;
        },
      ),
    );
    try {
      final data = await request.timeout(const Duration(seconds: 2));
      if (generation != _generation) return;
      _latest = data ?? const {'status': 'unavailable'};
      _receivedMs = _clock.elapsedMilliseconds;
    } on MissingPluginException {
      if (generation != _generation) return;
      _latest = const {'status': 'unsupported'};
      _timer?.cancel();
      _timer = null;
    } on TimeoutException {
      if (generation == _generation) _latest = const {'status': 'timeout'};
    } on PlatformException {
      if (generation == _generation) _latest = const {'status': 'unavailable'};
    }
  }

  Future<void> stop() async {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    _latest = const {'status': 'stopped'};
    _receivedMs = null;
  }
}
