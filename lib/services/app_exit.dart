import 'dart:async';

import 'package:pili_aurora/services/logger.dart';

typedef AppExitCleanup = (String phase, FutureOr<void> Function() action);

/// 退出时独立清理互不阻断，并发调用等待同一次退出；退出失败可重试。
class AppExit {
  AppExit({
    this.cleanup = const [],
    this.flushDiagnostics,
    required this.terminate,
    this.onFailure = _reportFailure,
  });

  final List<AppExitCleanup> cleanup;
  final Future<void> Function()? flushDiagnostics;
  final FutureOr<void> Function() terminate;
  final void Function(String phase, Object error, StackTrace stackTrace)
  onFailure;
  Future<void>? _pending;

  bool get isClosing => _pending != null;

  Future<void> close() => _pending ??= Future<void>.microtask(_close);

  Future<void> _close() async {
    try {
      for (final (phase, action) in cleanup) {
        await _release(phase, action);
      }
      if (flushDiagnostics case final flush?) {
        await _release(
          'diagnostics',
          () => flush().timeout(const Duration(seconds: 3)),
        );
      }
      try {
        await terminate();
      } catch (error, stackTrace) {
        _report('terminate', error, stackTrace);
        rethrow;
      }
    } finally {
      _pending = null;
    }
  }

  Future<void> _release(
    String phase,
    FutureOr<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error, stackTrace) {
      _report(phase, error, stackTrace);
    }
  }

  void _report(String phase, Object error, StackTrace stackTrace) {
    try {
      onFailure(phase, error, stackTrace);
    } catch (_) {
      // 诊断本身不可用时，仍须继续退出并保留实际退出失败。
    }
  }

  static void _reportFailure(
    String phase,
    Object error,
    StackTrace stackTrace,
  ) {
    logger.e(
      '应用退出阶段失败：$phase',
      error: error.runtimeType,
      stackTrace: stackTrace,
    );
  }
}
