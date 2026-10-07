import 'package:catcher_2/core/catcher_2.dart';
import 'package:catcher_2/model/report.dart';
import 'package:catcher_2/model/report_handler.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

class ConsoleHandler extends ReportHandler {
  final Level level;
  final bool enableDeviceParameters;
  final bool enableApplicationParameters;
  final bool enableCustomParameters;

  const ConsoleHandler({
    this.level = Level.warning,
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
      Catcher2.logger.log(
        level,
        info.isEmpty ? null : info,
        time: report.dateTime,
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
