import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

/// 应用只使用四个日志等级；过滤、存储和导出脱敏由 Diagnostics 统一负责。
class AppLogger {
  const AppLogger({
    required this.diagnostics,
    this.console,
    this.category = 'app',
  });

  final String category;
  AppLogger scoped(String category) =>
      AppLogger(diagnostics: diagnostics, console: console, category: category);

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
    final result = diagnostics.log(
      level,
      category,
      message,
      details: error,
      stack: stackTrace,
    );
    if (result != null && console != null) {
      final record = result.record;
      final output = console!;
      output(
        '[${record['time']}] ${level.name}: ${record['message']}'
        '${record['details'] == null ? '' : '\n${record['details']}'}'
        '${record['stack'] == null ? '' : '\n${record['stack']}'}',
      );
    }
  }
}
