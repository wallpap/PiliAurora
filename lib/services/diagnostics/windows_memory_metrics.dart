import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// 原生后台每五秒扫描；Dart 只读取缓存，差分快照只交付一次。
class WindowsMemoryMetrics {
  WindowsMemoryMetrics({required this.onSnapshot});
  final void Function(Map<String, Object?>) onSnapshot;
  static const _channel = MethodChannel('pili_aurora/windows_memory');
  Timer? _timer;
  int _generation = 0;
  int? _lastSampleId;
  int? _receivedMs;
  bool _reading = false;
  final _clock = Stopwatch()..start();
  Future<void> _commands = Future.value();
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
    _lastSampleId = null;
    _receivedMs = null;
    _latest = const {'status': 'warmingUp'};
    try {
      await (_commands = _commands.then(
        (_) => _channel.invokeMethod<void>('start'),
      ));
      if (generation != _generation) return;
      _timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _read(generation),
      );
      await _read(generation);
    } catch (_) {
      if (generation == _generation) _latest = const {'status': 'unavailable'};
      // 下一次启停仍可执行，不让一次失效通道污染命令链。
      _commands = Future.value();
    }
  }

  Future<void> _read(int generation) async {
    if (_reading) return;
    _reading = true;
    try {
      final data = await _channel.invokeMapMethod<String, Object?>(
        'sample',
        {'afterSampleId': _lastSampleId},
      );
      if (generation != _generation ||
          data == null ||
          data['unchanged'] == true) {
        return;
      }
      final id = data['sampleId'] as int?;
      final allocations = (data['allocations'] as List?) ?? const [];
      _latest = {
        for (final entry in data.entries)
          if (entry.key != 'allocations' && entry.key != 'changes')
            entry.key: entry.value,
        'trackedAllocationCount': allocations.length,
        'largest': allocations.take(8).toList(),
      };
      _receivedMs = _clock.elapsedMilliseconds;
      if (id == null || id == 0 || id == _lastSampleId) return;
      final previousId = _lastSampleId;
      _lastSampleId = id;
      onSnapshot({
        ...data,
        'previousSampleId': previousId,
        'skippedSnapshots': previousId == null
            ? 0
            : (id - previousId - 1).clamp(0, id),
      });
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
    if (!Platform.isWindows) return;
    try {
      await (_commands = _commands.then(
        (_) => _channel.invokeMethod<void>('stop'),
      ));
    } catch (_) {
      _commands = Future.value();
    }
  }
}
