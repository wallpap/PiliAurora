import 'dart:async' show unawaited;
import 'dart:io' show Directory, File, Platform;
import 'dart:math' as math;
import 'dart:typed_data' show Uint8List;

import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/common/widgets/custom_toast.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/utils/cache_manager.dart';
import 'package:pili_aurora/utils/device_utils.dart';
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

  static bool _sharing = false;
  static bool _downloading = false;

  // 返回系统分享状态：取消和平台无法确认均保留原始 status，不宣称分享成功。
  static Future<LoadingState<ShareResult>> onShareImg(String url) async {
    if (_sharing) return const Error('图片正在分享，请稍候');
    _sharing = true;
    final loading = _ImageLoading();
    try {
      loading.show('正在加载图片');
      final file = await CacheManager.manager.getSingleFile(url.http2https);
      loading.close();
      if (loading.cancelled) return const Error('已取消图片分享');
      return Success(
        await SharePlus.instance.share(
          ShareParams(files: [XFile(file.path)]),
        ),
      );
    } catch (error, stackTrace) {
      final failure = _failure('图片分享失败，请重试', error, stackTrace);
      if (!loading.cancelled) failure.toast();
      return failure;
    } finally {
      _sharing = false;
      loading.close();
    }
  }

  static Error _failure(String message, Object error, StackTrace stackTrace) {
    logger.w(message, error: error.runtimeType, stackTrace: stackTrace);
    return Error(message, cause: error, stackTrace: stackTrace);
  }

  /// 保留平台权限状态，拒绝、受限与插件查询失败不能混为已授权。
  static Future<LoadingState<PermissionStatus>> requestPer() async {
    try {
      final status = Platform.isAndroid
          ? await Permission.storage.request()
          : await Permission.photos.request();
      return Success(status);
    } catch (error, stackTrace) {
      return _failure('无法获取存储权限，请稍后重试', error, stackTrace);
    }
  }

  static Future<bool> openPermissionSettings() async {
    try {
      if (await openAppSettings()) return true;
      SmartDialog.showToast('无法打开系统设置，请手动前往应用权限设置');
    } catch (error, stackTrace) {
      _failure('无法打开系统设置，请手动前往应用权限设置', error, stackTrace).toast();
    }
    return false;
  }

  static Future<bool> checkPermissionDependOnSdkInt() async {
    if (Platform.isAndroid && DeviceUtils.sdkInt >= 29) return true;
    final result = await requestPer();
    if (result case Success(:final response)) {
      if (response == PermissionStatus.granted ||
          response == PermissionStatus.limited) {
        return true;
      }
      SmartDialog.show(
        builder: (context) => AlertDialog(
          title: const Text('提示'),
          content: Text(
            response == PermissionStatus.restricted
                ? '存储权限受系统限制，请检查设备权限设置'
                : '存储权限未授权',
          ),
          actions: [
            const TextButton(
              onPressed: SmartDialog.dismiss,
              child: Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                await SmartDialog.dismiss();
                await openPermissionSettings();
              },
              child: const Text('去授权'),
            ),
          ],
        ),
      );
    } else {
      result.toast();
    }
    return false;
  }

  static Future<bool> downloadLivePhoto({
    required String liveUrl,
  }) async {
    if (!_beginDownload()) return false;
    final loading = _ImageLoading(enabled: !silentDownImg);
    Directory? temporaryDirectory;
    try {
      if (PlatformUtils.isMobile && !await checkPermissionDependOnSdkInt()) {
        return false;
      }
      loading.show(PlatformUtils.isMobile ? '正在下载并保存' : '正在下载');

      final videoName = 'video_${Utils.getFileName(liveUrl)}';
      temporaryDirectory = await Directory(tmpDirPath)
          .createTemp('live-image-');
      final videoPath = path.join(temporaryDirectory.path, videoName);

      final res = await Request().downloadFile(liveUrl.http2https, videoPath);
      if (res.statusCode != 200) {
        final data = res.data;
        throw Error(
          data is Map && data['message'] is String
              ? data['message']
              : '视频下载失败，请重试',
          code: res.statusCode,
        );
      }

      if (loading.cancelled) return false;
      if (!PlatformUtils.isMobile) loading.close();
      final saved = await saveFileImg(
        filePath: videoPath,
        fileName: videoName,
        type: FileType.video,
        needToast: true,
      );
      return saved?.isSuccess == true;
    } catch (error, stackTrace) {
      final failure = _failure('动态图片保存失败，请重试', error, stackTrace);
      if (!loading.cancelled) failure.toast();
      return false;
    } finally {
      loading.close();
      try {
        // 下载使用独立目录，取消、失败与成功均只清理本次拥有的文件。
        if (temporaryDirectory != null) {
          await temporaryDirectory.delete(recursive: true);
        }
      } catch (error, stackTrace) {
        _failure('动态图片临时文件清理失败', error, stackTrace);
      }
      _downloading = false;
    }
  }

  static Future<bool> downloadImg(List<String> imgList) async {
    if (imgList.isEmpty) {
      SmartDialog.showToast('没有可保存的图片');
      return false;
    }
    if (!_beginDownload()) return false;
    final loading = _ImageLoading(enabled: !silentDownImg);
    try {
      if (PlatformUtils.isMobile && !await checkPermissionDependOnSdkInt()) {
        return false;
      }
      loading.show(PlatformUtils.isMobile ? '正在下载并保存原图' : '正在下载原图');
      final futures = imgList.toSet().map((url) async {
        final name = Utils.getFileName(url);
        final file = await CacheManager.manager.getSingleFile(url.http2https);
        return (file, name);
      });
      // 下载结果属于共享缓存，部分失败时不删除已成功的文件。
      final result = await Future.wait(futures);
      if (loading.cancelled) return false;
      if (PlatformUtils.isMobile) {
        final saved = await SaverGallery.saveFiles([
          for (final (file, name) in result)
            SaveFileData(
              filePath: file.path,
              fileName: name,
              albumPath: _albumPath,
            ),
        ], skipIfExists: false);
        if (!saved.isSuccess) {
          SmartDialog.showToast('保存失败，请检查相册权限后重试');
          return false;
        }
      } else {
        loading.close();
        final dst = await FilePicker.getDirectoryPath();
        if (dst == null) {
          SmartDialog.showToast('取消保存');
          return false;
        }
        for (final (src, name) in result) {
          final destination = path.join(dst, name);
          if (path.equals(
            path.absolute(src.path),
            path.absolute(destination),
          )) {
            continue; // 选择缓存所在目录时，文件已存在且归共享缓存所有。
          }
          var target = File(destination);
          var suffix = 1;
          while (target.existsSync()) {
            target = File(
              path.join(
                dst,
                '${path.basenameWithoutExtension(name)} (${suffix++})${path.extension(name)}',
              ),
            );
          }
          // 顺序复制，避免本批同名图片竞争同一目标；已有文件保留。
          await src.copy(target.path);
        }
      }
      SmartDialog.showToast(' 已保存 ');
      return true;
    } catch (error, stackTrace) {
      final failure = _failure('图片保存失败，请重试', error, stackTrace);
      if (!loading.cancelled) failure.toast();
      return false;
    } finally {
      loading.close();
      _downloading = false;
    }
  }

  static bool _beginDownload() {
    if (_downloading) {
      SmartDialog.showToast('图片正在保存，请稍候');
      return false;
    }
    _downloading = true;
    return true;
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
      final loading = _ImageLoading(enabled: showLoading)..show('正在保存');
      try {
        res = await SaverGallery.saveImage(
          bytes,
          fileName: fileName,
          albumPath: _albumPath,
          skipIfExists: false,
        );
      } finally {
        loading.close();
      }
      if (res.isSuccess) {
        SmartDialog.showToast(' 已保存 ');
      } else {
        SmartDialog.showToast('保存失败，请检查相册权限后重试');
      }
    } else {
      final savePath = await FilePicker.saveFile(
        type: FileType.image,
        fileName: fileName,
        bytes: bytes,
      );
      if (savePath == null) {
        SmartDialog.showToast("取消保存");
        return null;
      }
      SmartDialog.showToast(' 已保存 ');
      res = SaveResult(true, null);
    }
    return res;
  }

  /// 返回保存结果；用户取消选择时返回 null，文件缺失返回明确的失败结果。
  static Future<SaveResult?> saveFileImg({
    required String filePath,
    required String fileName,
    FileType type = FileType.image,
    bool needToast = false,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      SmartDialog.showToast("文件不存在");
      return SaveResult(false, '文件不存在');
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
        bytes: await file.readAsBytes(),
      );
      if (savePath == null) {
        SmartDialog.showToast("取消保存");
        return null;
      }
      res = SaveResult(true, null);
    }
    if (needToast) {
      if (res.isSuccess) {
        SmartDialog.showToast(' 已保存 ');
      } else {
        SmartDialog.showToast('保存失败，请检查相册权限后重试');
      }
    }
    return res;
  }
}

/// 每次操作只关闭自己的提示，偏好变化或其他操作不会改变其所有权。
final class _ImageLoading {
  _ImageLoading({this.enabled = true});

  final bool enabled;
  final String _tag = 'image-operation-${UniqueKey()}';
  bool _shown = false;
  bool cancelled = false;

  void show(String message) {
    if (!enabled || _shown) return;
    _shown = true;
    SmartDialog.show<void>(
      tag: _tag,
      builder: (_) => LoadingWidget(message),
      debounce: false,
      clickMaskDismiss: false,
      backType: SmartBackType.normal,
      onDismiss: () {
        if (_shown) cancelled = true;
      },
    );
  }

  void close() {
    if (!_shown) return;
    _shown = false;
    unawaited(_dismiss());
  }

  Future<void> _dismiss() async {
    try {
      await SmartDialog.dismiss(tag: _tag);
    } catch (error, stackTrace) {
      ImageUtils._failure('关闭图片加载提示失败', error, stackTrace);
    }
  }
}
