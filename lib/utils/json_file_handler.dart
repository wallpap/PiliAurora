import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/record_store.dart';
import 'package:pili_aurora/services/diagnostics/redact.dart';
import 'package:catcher_2/catcher_2.dart';

class JsonFileHandler extends ReportHandler {
  final bool enableDeviceParameters;
  final bool enableApplicationParameters;
  final bool enableStackTrace;
  final bool enableCustomParameters;
  final bool printLogs;
  final bool handleWhenRejected;

  static final _store = LoggerUtils.getLogsPath().then(
    DiagnosticRecordStore.new,
  );

  JsonFileHandler._({
    this.enableDeviceParameters = true,
    this.enableApplicationParameters = true,
    this.enableStackTrace = true,
    this.enableCustomParameters = true,
    this.printLogs = false,
    this.handleWhenRejected = false,
  });

  static Future<JsonFileHandler?> init({
    bool enableDeviceParameters = true,
    bool enableApplicationParameters = true,
    bool enableStackTrace = true,
    bool enableCustomParameters = true,
    bool printLogs = false,
    bool handleWhenRejected = false,
  }) async {
    try {
      await _store;
      return JsonFileHandler._(
        enableDeviceParameters: enableDeviceParameters,
        enableApplicationParameters: enableApplicationParameters,
        enableStackTrace: enableStackTrace,
        enableCustomParameters: enableCustomParameters,
        printLogs: printLogs,
        handleWhenRejected: handleWhenRejected,
      );
    } catch (e, s) {
      logger.e('Init log file', error: e, stackTrace: s);
      return null;
    }
  }

  static Future<void> clear() async => (await _store).clear();

  @override
  Future<bool> handle(Report report) async {
    if (!Diagnostics.instance.accepts(DiagnosticLogLevel.error)) return true;
    Diagnostics.instance.log(
      DiagnosticLogLevel.error,
      'exception',
      report.error,
      stack: report.stackTrace is StackTrace
          ? report.stackTrace as StackTrace
          : null,
    );
    try {
      return await _processReport(report);
    } catch (exc, stackTrace) {
      logger.e(
        'Write Json Exception occurred',
        error: exc,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<bool> _processReport(Report report) async {
    if (printLogs) {
      logger.d('Writing report to file');
    }
    final json = report.toJson(
      enableDeviceParameters: enableDeviceParameters,
      enableApplicationParameters: enableApplicationParameters,
      enableStackTrace: enableStackTrace,
      enableCustomParameters: enableCustomParameters,
    );
    final store = await _store;
    final accepted = store.add(
      Map<String, Object?>.from(DiagnosticRedactor.clean(json) as Map),
    );
    await store.flush();
    return accepted && store.lastError == null;
  }
}
