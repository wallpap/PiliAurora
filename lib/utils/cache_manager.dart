import 'dart:io' show Directory, File;

import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

abstract final class CacheManager {
  static late final DefaultCacheManager manager;

  static Future<void> ensureInitialized({Directory? directory}) =>
      DefaultCacheManager.init(
        maxNrOfCacheLength: Pref.maxCacheSize.toInt(),
        cacheDirectoryProvider: directory == null
            ? getTemporaryDirectory
            : () async => directory,
      ).then((i) => manager = i);

  /// 读取失败保留异常；0 仅表示实际没有缓存文件。
  static Future<int> loadApplicationCache() async {
    final directory = PlatformUtils.isDesktop
        ? Directory(manager.cacheDir)
        : await getTemporaryDirectory();
    return getTotalSizeOfFilesInDir(directory);
  }

  static Future<int> getTotalSizeOfFilesInDir(Directory directory) async {
    var total = 0;
    final cacheDirectory = path.equals(directory.path, manager.cacheDir);
    await for (final child in directory.list(followLinks: false)) {
      if (child is File) {
        total += await child.length();
      } else if (child is Directory && !cacheDirectory) {
        // 图片缓存只计实际文件，Hive 元数据不属于可清除的图片内容。
        total += await getTotalSizeOfFilesInDir(child);
      }
    }
    return total;
  }

  // 缓存大小格式转换
  static String formatSize(num value) {
    const unitArr = ['B', 'K', 'M', 'G', 'T', 'P'];
    int index = 0;
    while (value >= 1024) {
      index++;
      value = value / 1024;
    }
    String size = value.toStringAsFixed(2);
    return size + (unitArr.elementAtOrNull(index) ?? '');
  }

  /// 全部步骤完成才确认成功；失败可能发生在部分缓存已删除之后。
  static Future<void> clearLibraryCache() async {
    await manager.emptyCache();
    final cacheDirectory = Directory(manager.cacheDir);
    // 底层清理会容忍孤立文件删除失败，显式排空残留才能确认清理结果。
    await for (final file in cacheDirectory.list(followLinks: false)) {
      if (file is File) await file.delete();
    }
    if (PlatformUtils.isDesktop) return;
    final tempDirectory = await getTemporaryDirectory();
    await for (final file in tempDirectory.list(followLinks: false)) {
      if (file is Directory && path.equals(file.path, manager.cacheDir)) {
        continue;
      }
      await file.delete(recursive: true);
    }
  }
}
