import 'dart:io' show Platform, Directory, File;

import 'package:flutter/services.dart' show rootBundle;
import 'package:pili_aurora/services/logger.dart';
import 'package:path/path.dart' as path;

abstract final class AssetUtils {
  /// from media-kit AssetLoader
  static String? tryGetPath(String key) {
    if (Platform.isWindows) {
      return path.join(
        path.dirname(Platform.resolvedExecutable),
        'data',
        'flutter_assets',
        key,
      );
    }
    return null;
  }

  /// 所有资源准备完成后返回目录；复制失败保留原始异常，允许调用方重试。
  static Future<String> getOrCopy(
    String src,
    Iterable<String> files,
    String dst,
  ) async {
    final requiredFiles = files.toSet();
    final parsedSrc = tryGetPath(src);
    if (parsedSrc != null) {
      final source = Directory(parsedSrc);
      if (source.existsSync()) {
        var complete = true;
        for (final name in requiredFiles) {
          if (!File(path.join(parsedSrc, name)).existsSync()) {
            complete = false;
            break;
          }
        }
        if (complete) return source.absolute.path;
      }
    }

    final directory = await Directory(dst).create(recursive: true);
    final staging = await directory.createTemp('.asset-');
    try {
      for (final name in requiredFiles) {
        final data = await rootBundle.load('$src/$name');
        final target = File(path.join(dst, name));
        if (target.existsSync() &&
            await target.length() == data.lengthInBytes) {
          continue;
        }
        final staged = File(path.join(staging.path, name));
        await staged.parent.create(recursive: true);
        await staged.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
        await target.parent.create(recursive: true);
        await staged.rename(target.path);
      }
      return dst;
    } finally {
      try {
        await staging.delete(recursive: true);
      } catch (error, stackTrace) {
        logger.w(
          '资源临时文件清理失败',
          error: error.runtimeType,
          stackTrace: stackTrace,
        );
      }
    }
  }
}
