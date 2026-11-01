import 'package:catcher_2/catcher_2.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

/// 异常捕获只负责适配报告，过滤、持久化与导出脱敏交给统一日志模块。
class DiagnosticReportHandler extends ReportHandler {
  DiagnosticReportHandler({Diagnostics? diagnostics})
    : diagnostics = diagnostics ?? Diagnostics.instance;

  final Diagnostics diagnostics;

  @override
  Future<bool> handle(Report report) async {
    final record = diagnostics.log(
      DiagnosticLogLevel.error,
      'exception',
      report.error,
      stack: report.stackTrace == null
          ? null
          : StackTrace.fromString(report.stackTrace.toString()),
      details: {
        'device': {
          for (final entry in report.deviceParameters.entries)
            if (const {
              'platform',
              'version',
              'model',
              'manufacturer',
              'brand',
              'isPhysicalDevice',
              'systemName',
              'systemVersion',
            }.contains(entry.key))
              entry.key: entry.value,
        },
        'application': report.applicationParameters,
        'build': report.customParameters,
      },
    );
    if (record == null || !await record.accepted) return false;
    await diagnostics.flush();
    return diagnostics.storageError == null;
  }
}
