import 'package:catcher_2/catcher_2.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

/// 异常捕获只负责适配报告，过滤、脱敏与持久化交给统一日志模块。
class DiagnosticReportHandler extends ReportHandler {
  DiagnosticReportHandler({Diagnostics? diagnostics})
    : diagnostics = diagnostics ?? Diagnostics.instance;

  final Diagnostics diagnostics;

  @override
  Future<bool> handle(Report report) async {
    diagnostics.log(
      DiagnosticLogLevel.error,
      'exception',
      report.error,
      stack: report.stackTrace == null
          ? null
          : StackTrace.fromString(report.stackTrace.toString()),
      details: {
        'device': report.deviceParameters,
        'application': report.applicationParameters,
        'build': report.customParameters,
      },
    );
    await diagnostics.flush();
    return diagnostics.storageError == null;
  }
}
