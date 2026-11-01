import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// media_kit_video 原生输出资源的生命周期计数。
///
/// 字段中的 estimatedBytes 是资源名义尺寸，用来和进程快照对齐，不代表
/// 驱动实际驻留；快照由原生插件直接读取，不访问逐帧渲染路径。
class WindowsNativeMemoryMetrics {
  static const _channel = MethodChannel('com.alexmercerind/media_kit_video');
  Timer? _timer;
  int _generation = 0;
  bool _reading = false;
  Map<String, Object?> _latest = const {'status': 'warmingUp'};
  final _clock = Stopwatch()..start();
  int? _receivedMs;

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
    try {
      _timer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _read(generation),
      );
      await _read(generation);
    } catch (_) {
      if (generation == _generation) _latest = const {'status': 'unavailable'};
    }
  }

  Future<void> _read(int generation) async {
    if (_reading) return;
    _reading = true;
    try {
      final data = await _channel.invokeMapMethod<String, Object?>(
        'VideoOutputManager.MemoryStats',
      );
      if (generation == _generation && data != null) {
        _latest = data;
        _receivedMs = _clock.elapsedMilliseconds;
      }
    } catch (_) {
      if (generation == _generation) _latest = const {'status': 'unavailable'};
    } finally {
      _reading = false;
    }
  }

  Future<void> stop() async {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    _reading = false;
    _latest = const {'status': 'stopped'};
    _receivedMs = null;
  }
}
