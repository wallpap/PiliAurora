import 'dart:io';

import 'package:pili_aurora/utils/json_file_handler.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/app_logger.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/build_config.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final logger = AppLogger(
  diagnostics: Diagnostics.instance,
  console: kDebugMode ? debugPrint : null,
);

abstract final class LoggerUtils {
  static File? _logFile;

  static Future<void> initialize() async {
    Diagnostics.instance.register(
      'app',
      () => {
        'version': '${BuildConfig.versionName}+${BuildConfig.versionCode}',
        'commit': BuildConfig.commitHash,
      },
    );
    await Diagnostics.instance.initialize(
      directory: Directory(p.join(appSupportDirPath, 'diagnostics')),
      level: Pref.enableLog
          ? DiagnosticLogLevel.parse(Pref.diagnosticLogLevel)
          : DiagnosticLogLevel.off,
      tracing: Pref.performanceTracing,
      intervalMs: Pref.performanceIntervalMs,
      saveSettings: (settings) => GStorage.setting.putAll({
        SettingBoxKey.diagnosticLogLevel: settings['level'],
        SettingBoxKey.enableLog:
            settings['level'] != DiagnosticLogLevel.off.name,
        SettingBoxKey.performanceTracing: settings['tracing'],
        SettingBoxKey.performanceIntervalMs: settings['intervalMs'],
      }),
    );
  }

  static Future<File> getLogsPath() async {
    final file = _logFile ??= File(
      p.join(
        (await getApplicationDocumentsDirectory()).path,
        '.pili_logs.json',
      ),
    );
    if (!file.existsSync()) {
      await file.create(recursive: true);
    }
    return file;
  }

  static Future<bool> clearLogs() async {
    try {
      await JsonFileHandler.clear();
    } catch (e) {
      // if (kDebugMode) debugPrint('Error clearing file: $e');
      return false;
    }
    return true;
  }
}
