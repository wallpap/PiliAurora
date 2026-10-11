import 'dart:io';

import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// 按平台和设置选择下载目录；无效的桌面自定义目录会回退到默认目录。
Future<void> initializeDownloadPath() async {
  if (PlatformUtils.isDesktop) {
    final customDownPath = Pref.downloadPath;
    if (customDownPath != null && customDownPath.isNotEmpty) {
      try {
        final dir = Directory(customDownPath);
        if (!dir.existsSync()) {
          await dir.create(recursive: true);
        }
        downloadPath = customDownPath;
      } catch (e) {
        downloadPath = defDownloadPath;
        await GStorage.setting.delete(SettingBoxKey.downloadPath);
        logger.w('download path error', error: e);
      }
    } else {
      downloadPath = defDownloadPath;
    }
  } else if (Platform.isAndroid) {
    final externalStorageDirPath = (await getExternalStorageDirectory())?.path;
    downloadPath = externalStorageDirPath != null
        ? path.join(externalStorageDirPath, PathUtils.downloadDir)
        : defDownloadPath;
  } else {
    downloadPath = defDownloadPath;
  }
}

/// 记录系统临时目录，供临时文件和短期缓存使用。
Future<void> initializeTemporaryPath() async {
  tmpDirPath = (await getTemporaryDirectory()).path;
}

/// 初始化应用支持目录，作为应用配置和平台数据目录的根路径。
Future<void> initializeSupportPath() async {
  appSupportDirPath = (await getApplicationSupportDirectory()).path;
}
