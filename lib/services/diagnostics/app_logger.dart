import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/redact.dart';

/// 应用只使用四个日志等级；过滤、存储和脱敏由 Diagnostics 统一负责。
class AppLogger {
  const AppLogger({required this.diagnostics, this.console});

  final Diagnostics diagnostics;
  final void Function(String)? console;

  void d(Object? message, {Object? error, StackTrace? stackTrace}) =>
      _log(DiagnosticLogLevel.debug, message, error, stackTrace);

  void i(Object? message, {Object? error, StackTrace? stackTrace}) =>
      _log(DiagnosticLogLevel.info, message, error, stackTrace);

  void w(Object? message, {Object? error, StackTrace? stackTrace}) =>
      _log(DiagnosticLogLevel.warning, message, error, stackTrace);

  void e(Object? message, {Object? error, StackTrace? stackTrace}) =>
      _log(DiagnosticLogLevel.error, message, error, stackTrace);

  void _log(
    DiagnosticLogLevel level,
    Object? message,
    Object? error,
    StackTrace? stackTrace,
  ) {
    // 关闭的等级不格式化消息，也不构造控制台输出。
    if (!diagnostics.accepts(level)) return;
    final safeMessage = DiagnosticRedactor.clean(message);
    diagnostics.log(
      level,
      'app',
      safeMessage,
      details: error,
      stack: stackTrace,
    );
    if (console case final output?) {
      output(
        '[${DateTime.now().toIso8601String()}] ${level.name}: '
        '${DiagnosticRedactor.text(safeMessage)}'
        '${error == null ? '' : '\n${DiagnosticRedactor.clean(error)}'}'
        '${stackTrace == null ? '' : '\n${DiagnosticRedactor.text(stackTrace)}'}',
      );
    }
  }
}
