import 'package:catcher_2/utils/log_printer.dart';
import 'package:flutter/foundation.dart';

class Report {
  /// Creates report instance
  const Report(
    this.error,
    this.stackTrace,
    this.dateTime,
    this.deviceParameters,
    this.applicationParameters,
    this.customParameters,
    this.errorDetails,
  );

  /// Error that has been caught
  final Object error;

  /// Stack trace of error
  final Object? stackTrace;

  /// Time when it was caught
  final DateTime dateTime;

  /// Device info
  final Map<String, dynamic> deviceParameters;

  /// Application info
  final Map<String, dynamic> applicationParameters;

  /// Custom parameters passed to report
  final Map<String, dynamic> customParameters;

  /// FlutterErrorDetails data if present
  final FlutterErrorDetails? errorDetails;

  /// Creates json from current instance
  Map<String, dynamic> toJson({
    bool enableDeviceParameters = true,
    bool enableApplicationParameters = true,
    bool enableStackTrace = true,
    bool enableCustomParameters = false,
  }) {
    return {
      'error': error.toString(),
      'dateTime': dateTime.toIso8601String(),
      if (enableStackTrace && stackTrace != null)
        'stackTrace': stackTrace?.toString(),
      if (enableDeviceParameters && deviceParameters.isNotEmpty)
        'deviceParameters': deviceParameters,
      if (enableApplicationParameters && applicationParameters.isNotEmpty)
        'applicationParameters': applicationParameters,
      if (enableCustomParameters && customParameters.isNotEmpty)
        'customParameters': customParameters,
    };
  }

  Report.fromJson(Map<String, dynamic> json)
      : error = json['error'] ?? 'null',
        stackTrace = json['stackTrace'],
        dateTime = DateTime.tryParse(json['dateTime'] ?? '') ?? DateTime(1970),
        deviceParameters = json['deviceParameters'] ?? const {},
        applicationParameters = json['applicationParameters'] ?? const {},
        customParameters = json['customParameters'] ?? const {},
        errorDetails = null;

  static String _params2String(Map<String, dynamic> params) {
    final sb = StringBuffer();
    for (var entry in params.entries) {
      final value = entry.value?.toString();
      if (value != null && value.isNotEmpty) {
        sb.write('${entry.key}: ${entry.value}\n');
      }
    }
    return sb.toString();
  }

  String formatInfo({bool device = true, bool app = true, bool custom = true}) {
    final sb = StringBuffer();
    if (device) {
      sb.writeln('------- DEVICE INFO -------');
      sb.write(_params2String(deviceParameters));
    }
    if (app) {
      sb.writeln('------- APP INFO -------');
      sb.write(_params2String(applicationParameters));
    }
    if (custom) {
      sb.writeln('------- CUSTOM INFO -------');
      sb.write(_params2String(customParameters));
    }
    return sb.toString();
  }

  @override
  String toString() {
    return '${formatInfo()}'
        '------- TIME -------\n$dateTime\n'
        '------- ERROR -------\n$error\n'
        '------- STACK TRACE -------\n${PrettyLogPrinter.formatStackString(stackTrace?.toString())?.join("\n")}\n';
  }
}
