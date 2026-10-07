import 'package:catcher_2/core/catcher_2.dart';
import 'package:catcher_2/model/report.dart';
import 'package:catcher_2/model/report_handler.dart';
import 'package:flutter/foundation.dart';
import 'package:catcher_2/model/report_log.dart';

class ConsoleHandler extends ReportHandler {
  final ReportLogLevel level;
  final bool enableDeviceParameters;
  final bool enableApplicationParameters;
  final bool enableCustomParameters;

  const ConsoleHandler({
    this.level = ReportLogLevel.warning,
    this.enableDeviceParameters = kReleaseMode,
    this.enableApplicationParameters = kReleaseMode,
    this.enableCustomParameters = kReleaseMode,
  });

  @override
  Future<bool> handle(Report report) {
    final stack = report.stackTrace;
    return Future.sync(() {
      final info = report.formatInfo(
        device: enableDeviceParameters,
        app: enableApplicationParameters,
        custom: enableCustomParameters,
      );
      Catcher2.logger?.call(
        level,
        info.isEmpty ? null : info,
        error: report.error,
        stackTrace: stack is StackTrace
            ? stack
            : stack == null
                ? null
                : StackTrace.fromString(stack.toString()),
      );
      return true;
    });
  }
}
