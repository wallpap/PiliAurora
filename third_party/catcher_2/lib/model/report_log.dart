/// 捕获器只传递日志事件，由宿主决定过滤、脱敏和输出，避免绑定日志工具箱。
enum ReportLogLevel { debug, info, warning, error }

typedef ReportLog = void Function(
  ReportLogLevel level,
  Object? message, {
  Object? error,
  StackTrace? stackTrace,
});
