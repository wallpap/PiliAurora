import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:pili_aurora/utils/android/bindings.g.dart';
import 'package:pili_aurora/utils/device_utils.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:jni/jni.dart';

abstract final class PiliAndroidHelper {
  @pragma('vm:prefer-inline')
  static void back() => AndroidHelper.back();

  static void biliSendCommAntifraud(
    int action,
    int oid,
    int type,
    int rpId,
    int root,
    int parent,
    int ctime,
    String commentText,
    List pictures,
    String sourceId,
    int uid,
    String cookie,
  ) {
    final jCommentText = commentText.toJString();
    final jSourceId = sourceId.toJString();
    final jCookie = cookie.toJString();
    final jPictures = pictures.isEmpty
        ? null
        : jsonEncode(pictures).toJString();

    try {
      AndroidHelper.biliSendCommAntifraud(
        action,
        oid,
        type,
        rpId,
        root,
        parent,
        ctime,
        jCommentText,
        jPictures,
        jSourceId,
        uid,
        jCookie,
      );
    } catch (e) {
      Utils.reportError(e);
    } finally {
      jCommentText.release();
      jSourceId.release();
      jCookie.release();
      jPictures?.release();
    }
  }

  static void openLinkVerifySettings() {
    try {
      AndroidHelper.openLinkVerifySettings();
    } catch (error, stack) {
      logger.w('打开链接设置失败', error: error.runtimeType, stackTrace: stack);
      SmartDialog.showToast('无法打开链接设置，请从系统设置进入');
    }
  }

  static bool openMusic(String title, String? artist, String? album) {
    final jTitle = title.toJString();
    final jArtist = artist?.toJString();
    final jAlbum = album?.toJString();
    try {
      return AndroidHelper.openMusic(jTitle, jArtist, jAlbum);
    } finally {
      jTitle.release();
      jArtist?.release();
      jAlbum?.release();
    }
  }

  @pragma('vm:prefer-inline')
  static void enterPip(
    int width,
    int height, {
    required bool autoEnter,
    required bool isLive,
    required bool isPlaying,
  }) => AndroidHelper.enterPip(
    PlatformDispatcher.instance.engineId!,
    width,
    height,
    autoEnter,
    isLive,
    isPlaying,
  );

  @pragma('vm:prefer-inline')
  static void disableAutoEnterPip() =>
      AndroidHelper.disableAutoEnterPip(PlatformDispatcher.instance.engineId!);

  static (int, int)? maxScreenSize() {
    final jIArr = AndroidHelper.maxScreenSize();
    if (jIArr != null) {
      try {
        return (jIArr[0], jIArr[1]);
      } finally {
        jIArr.release();
      }
    }
    return null;
  }

  static void createShortcut(String id, String uri, String label, String path) {
    final jId = id.toJString();
    final jUri = uri.toJString();
    final jLabel = label.toJString();
    final jPath = path.toJString();
    try {
      AndroidHelper.createShortcut(jId, jUri, jLabel, jPath);
    } finally {
      jId.release();
      jUri.release();
      jLabel.release();
      jPath.release();
    }
  }

  static Future<void> openUrl(
    String url, {
    String domain = '*.bilibili.com',
  }) async {
    JString? jDomain;
    JString? jUrl;
    try {
      if (!Platform.isAndroid || DeviceUtils.sdkInt < 31) {
        await PageUtils.launchURL(url);
        return;
      }
      jDomain = domain.toJString();
      if (AndroidHelper.isDomainVerified(jDomain)) {
        jUrl = url.toJString();
        final jStr = AndroidHelper.openUrl(jUrl);
        if (jStr != null) {
          // 原生返回值可能包含 Intent 与地址，不向用户交付异常正文。
          jStr.release();
          SmartDialog.showToast('无法打开链接，请检查可用的浏览器或应用');
        }
      } else {
        await PageUtils.launchURL(url);
      }
    } catch (error, stack) {
      logger.w('启动外部链接失败', error: error.runtimeType, stackTrace: stack);
      SmartDialog.showToast('无法打开链接，请检查可用的浏览器或应用');
    } finally {
      jDomain?.release();
      jUrl?.release();
    }
  }
}
