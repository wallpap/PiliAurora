import 'dart:async' show FutureOr;
import 'dart:io' show File, Platform;
import 'dart:math' as math;
import 'dart:typed_data' show Uint8List;

import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/utils/cache_manager.dart';
import 'package:pili_aurora/utils/device_utils.dart';
import 'package:pili_aurora/utils/extension/file_ext.dart';
import 'package:pili_aurora/utils/extension/string_ext.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/permission_handler.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;
import 'package:saver_gallery/saver_gallery.dart';
import 'package:share_plus/share_plus.dart';

abstract final class ImageUtils {
  static bool silentDownImg = Pref.silentDownImg;
  static final _albumPath = Platform.isAndroid
      ? 'Pictures/${Constants.appName}'
      : Constants.appName;

  // 图片分享
  static Future<void> onShareImg(String url) async {
    try {
      SmartDialog.showLoading();
      final res = await CacheManager.manager.getSingleFile(
        url.http2https,
      );
      SmartDialog.dismiss();
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(res.path)],
        ),
      );
    } catch (e) {
      SmartDialog.showToast(e.toString());
    } finally {
      SmartDialog.dismiss(status: .loading);
    }
  }

  // 获取存储权限
  static Future<bool> requestPer() async {
    final status = Platform.isAndroid
        ? await Permission.storage.request()
        : await Permission.photos.request();
    if (status == PermissionStatus.denied ||
        status == PermissionStatus.permanentlyDenied) {
      SmartDialog.show(
        builder: (context) => AlertDialog(
          title: const Text('提示'),
          content: const Text('存储权限未授权'),
          actions: [
            TextButton(
              onPressed: () {
                SmartDialog.dismiss();
                openAppSettings();
              },
              child: const Text('去授权'),
            ),
          ],
        ),
      );
      return false;
    }
    return true;
  }

  static FutureOr<bool> checkPermissionDependOnSdkInt() {
    if (Platform.isAndroid && DeviceUtils.sdkInt >= 29) return true;
    return requestPer();
  }

  static Future<bool> downloadLivePhoto({
    required String liveUrl,
  }) async {
    try {
      if (PlatformUtils.isMobile && !await checkPermissionDependOnSdkInt()) {
        return false;
      }
      if (!silentDownImg) SmartDialog.showLoading(msg: '正在下载');

      String videoName = "video_${Utils.getFileName(liveUrl)}";
      String videoPath = '$tmpDirPath/$videoName';

      final res = await Request().downloadFile(liveUrl.http2https, videoPath);
      if (res.statusCode != 200) throw '${res.statusCode}';

      if (!silentDownImg) SmartDialog.showLoading(msg: '正在保存');
      await saveFileImg(
        filePath: videoPath,
        fileName: videoName,
        type: FileType.video,
        needToast: true,
      );
      return true;
    } catch (err) {
      SmartDialog.showToast(err.toString());
      return false;
    } finally {
      if (!silentDownImg) SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  static Future<bool> downloadImg(List<String> imgList) async {
    if (PlatformUtils.isMobile && !await checkPermissionDependOnSdkInt()) {
      return false;
    }
    if (!silentDownImg) {
      SmartDialog.showLoading(msg: '正在下载原图');
    }
    final futures = imgList.map((url) async {
      final name = Utils.getFileName(url);
      final file = await CacheManager.manager.getSingleFile(url.http2https);
      return (file, name);
    });
    try {
      // 下载结果属于共享缓存，部分失败时不删除已成功的文件。
      final result = await Future.wait(futures, eagerError: true);
      if (PlatformUtils.isMobile) {
        await SaverGallery.saveFiles([
          for (final (file, name) in result)
            SaveFileData(
              filePath: file.path,
              fileName: name,
              albumPath: _albumPath,
            ),
        ], skipIfExists: false);
      } else {
        final dst = await FilePicker.getDirectoryPath();
        if (dst == null) {
          SmartDialog.showToast('取消保存');
          return false;
        }
        await Future.wait([
          for (final (src, name) in result)
            src.moveOrCopy(path.join(dst, name)),
        ]);
      }
      SmartDialog.showToast(' 已保存 ');
      return true;
    } catch (_) {
      SmartDialog.showToast('保存失败');
      return false;
    } finally {
      if (!silentDownImg) SmartDialog.dismiss(status: .loading);
    }
  }

  static final _suffixRegex = RegExp(
    r'\.(jpg|jpeg|png|webp|gif|avif)$',
    caseSensitive: false,
  );
  static String safeThumbnailUrl(String? src) {
    if (src != null && _suffixRegex.hasMatch(src)) {
      return thumbnailUrl(src);
    }
    return src.http2https;
  }

  static final _thumbRegex = RegExp(
    r'(@(\d+[a-z]_?)*)(\..*)?$',
    caseSensitive: false,
  );
  static String thumbnailUrl(String? src, [int maxQuality = 1]) {
    if (src != null && maxQuality != 100) {
      maxQuality = math.max(maxQuality, GlobalData().imgQuality);
      bool hasMatch = false;
      src = src.splitMapJoin(
        _thumbRegex,
        onMatch: (match) {
          hasMatch = true;
          String suffix = match.group(3) ?? '.webp';
          return '${match.group(1)}_${maxQuality}q$suffix';
        },
        onNonMatch: (String str) {
          return str;
        },
      );
      if (!hasMatch) {
        src += '@${maxQuality}q.webp';
      }
    }
    return src.http2https;
  }

  /// 在 CDN 缩小动画源文件，避免多帧解码忽略本地目标尺寸。
  static String thumbnailUrlForSize(
    String? src, {
    int quality = 1,
    int? width,
    int? height,
    int maxDecodePixels = 1 << 20,
  }) {
    final url = thumbnailUrl(src, quality);
    if (quality == 100 || (width == null && height == null)) return url;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !(uri.host.endsWith('.hdslb.com') ||
            uri.host.endsWith('.biliimg.com')) ||
        !uri.path.startsWith('/bfs/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      return url;
    }
    final match = _thumbRegex.firstMatch(uri.path);
    if (match == null) return url;
    final options = match
        .group(1)!
        .substring(1)
        .split('_')
        .where((part) => part.isNotEmpty)
        .toList();
    // 已指定尺寸或裁剪的源地址沿用原有构图，尺寸补充用于质量型缩略请求。
    if (options.any((part) => RegExp(r'^\d+[whpec]$').hasMatch(part))) {
      return url;
    }

    var targetWidth = width?.clamp(1, 4096);
    var targetHeight = height?.clamp(1, 4096);
    targetWidth ??= (maxDecodePixels ~/ targetHeight!).clamp(1, 4096);
    targetHeight ??= (maxDecodePixels ~/ targetWidth).clamp(1, 4096);
    final ratio = math.min(
      1.0,
      math.sqrt(maxDecodePixels / (targetWidth * targetHeight)),
    );
    final boundedWidth = math.max(1, (targetWidth * ratio).floor());
    final boundedHeight = math.max(1, (targetHeight * ratio).floor());
    final suffix = options.isEmpty ? '' : '_${options.join('_')}';
    return uri
        .replace(
          path:
              '${uri.path.substring(0, match.start)}'
              '@${boundedWidth}w_${boundedHeight}h$suffix${match.group(3) ?? '.webp'}',
        )
        .toString();
  }

  static Future<SaveResult?> saveByteImg({
    required Uint8List bytes,
    required String fileName,
    String ext = 'png',
    bool showLoading = true,
  }) async {
    SaveResult? res;
    fileName += '.$ext';
    if (PlatformUtils.isMobile) {
      if (showLoading) SmartDialog.showLoading(msg: '正在保存');
      res = await SaverGallery.saveImage(
        bytes,
        fileName: fileName,
        albumPath: _albumPath,
        skipIfExists: false,
      );
      SmartDialog.dismiss();
      if (res.isSuccess) {
        SmartDialog.showToast(' 已保存 ');
      } else {
        SmartDialog.showToast('保存失败，${res.errorMessage}');
      }
    } else {
      SmartDialog.dismiss();
      final savePath = await FilePicker.saveFile(
        type: FileType.image,
        fileName: fileName,
        bytes: Uint8List(0),
      );
      if (savePath == null) {
        SmartDialog.showToast("取消保存");
        return null;
      }
      await File(savePath.toFilePath()).writeAsBytes(bytes);
      SmartDialog.showToast(' 已保存 ');
      res = SaveResult(true, null);
    }
    return res;
  }

  static Future<void> saveFileImg({
    required String filePath,
    required String fileName,
    FileType type = FileType.image,
    bool needToast = false,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      SmartDialog.showToast("文件不存在");
      return;
    }
    SaveResult? res;
    if (PlatformUtils.isMobile) {
      res = await SaverGallery.saveFile(
        filePath: filePath,
        fileName: fileName,
        albumPath: _albumPath,
        skipIfExists: false,
      );
    } else {
      final savePath = await FilePicker.saveFile(
        type: type,
        fileName: fileName,
        bytes: Uint8List(0),
      );
      if (savePath == null) {
        SmartDialog.showToast("取消保存");
        return;
      }
      await file.moveOrCopy(savePath.toFilePath());
      res = SaveResult(true, null);
    }
    if (needToast) {
      if (res.isSuccess) {
        SmartDialog.showToast(' 已保存 ');
      } else {
        SmartDialog.showToast('保存失败，${res.errorMessage}');
      }
    }
  }
}
