import 'dart:io';

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
      level: DiagnosticLogLevel.parse(Pref.diagnosticLogLevel),
      legacyReports: File(
        p.join(
          (await getApplicationDocumentsDirectory()).path,
          '.pili_logs.json',
        ),
      ),
      playerLevel: DiagnosticLogLevel.parse(Pref.playerDiagnosticLogLevel),
      tracing: Pref.performanceTracing,
      intervalMs: Pref.performanceIntervalMs,
      saveSettings: (settings) => GStorage.setting.putAll({
        SettingBoxKey.diagnosticLogLevel: settings['level'],
        SettingBoxKey.playerDiagnosticLogLevel: settings['playerLevel'],
        // 保持旧开关与等级一致，兼容已有备份。
        SettingBoxKey.enableLog:
            settings['level'] != DiagnosticLogLevel.off.name,
        SettingBoxKey.performanceTracing: settings['tracing'],
        SettingBoxKey.performanceIntervalMs: settings['intervalMs'],
      }),
    );
  }
}
