import 'dart:io' show Platform;

import 'package:pili_aurora/build_config.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/browser_ua.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/app_release.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

abstract final class Update {
  static const _dialogTag = 'app-update';
  static bool _checking = false;

  static Future<void> checkUpdate([bool isAuto = true]) async {
    if ((kDebugMode && isAuto) || _checking) return;
    _checking = true;
    try {
      final res = await Request().get(
        Api.latestApp,
        queryParameters: {'per_page': 100},
        options: Options(
          headers: {'user-agent': BrowserUa.mob},
          extra: {'account': const NoAccount()},
        ),
      );
      final release = AppRelease.latestStable(res.data);
      if (release == null) {
        if (!isAuto) SmartDialog.showToast('暂无已发布的正式版本');
        return;
      }
      if (!release.isNewerThan(BuildConfig.versionName)) {
        if (!isAuto) SmartDialog.showToast('当前版本已是最新');
        return;
      }
      if (isAuto && Pref.updateIgnoredVersion == release.tag) return;

      final actions = <Widget>[
        TextButton(
          onPressed: () => SmartDialog.dismiss(tag: _dialogTag),
          child: const Text('稍后'),
        ),
        if (isAuto)
          TextButton(
            onPressed: () {
              SmartDialog.dismiss(tag: _dialogTag);
              GStorage.setting.put(
                SettingBoxKey.updateIgnoredVersion,
                release.tag,
              );
            },
            child: const Text('此版本不再提醒'),
          ),
      ];
      if (Platform.isWindows) {
        actions.addAll([
          TextButton(
            onPressed:
                release.downloadUrl(
                      platform: 'windows',
                      extension: 'zip',
                    ) ==
                    null
                ? null
                : () => onDownload(release, extension: 'zip'),
            child: const Text('便携版 ZIP'),
          ),
          TextButton(
            onPressed:
                release.downloadUrl(
                      platform: 'windows',
                      extension: 'exe',
                    ) ==
                    null
                ? null
                : () => onDownload(release, extension: 'exe'),
            child: const Text('安装版 EXE'),
          ),
        ]);
      } else {
        actions.add(
          TextButton(
            onPressed: () => onDownload(release),
            child: const Text('下载更新'),
          ),
        );
      }

      SmartDialog.show(
        tag: _dialogTag,
        keepSingle: true,
        animationType: SmartAnimationType.centerFade_otherSlide,
        builder: (context) => AlertDialog(
          title: Text('发现新版本 ${release.tag}'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640, maxHeight: 420),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '当前版本：${BuildConfig.versionName}+${BuildConfig.versionCode}',
                  ),
                  const SizedBox(height: 12),
                  Text(release.notes.isEmpty ? '本次发布未提供更新说明。' : release.notes),
                ],
              ),
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          actions: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final action in actions)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: action,
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    } catch (e, stackTrace) {
      logger.w('检查更新失败', error: e, stackTrace: stackTrace);
      if (!isAuto) SmartDialog.showToast('检查更新失败，请检查网络或前往发布页面');
    } finally {
      _checking = false;
    }
  }

  static String _releasePage(AppRelease release) =>
      '${Constants.sourceCodeUrl}/releases/tag/${Uri.encodeComponent(release.tag)}';

  static Future<void> onDownload(
    AppRelease release, {
    String? extension,
  }) async {
    await SmartDialog.dismiss(tag: _dialogTag);
    try {
      final abis = Platform.isAndroid
          ? (await DeviceInfoPlugin().androidInfo).supportedAbis
          : const <String>[];
      final url = release.downloadUrl(
        platform: Platform.operatingSystem,
        extension: extension,
        supportedAbis: abis,
      );
      if (url == null) {
        SmartDialog.showToast('该版本暂无适用的安装包，请在发布页面查看');
      }
      await PageUtils.launchURL(url ?? _releasePage(release));
    } catch (e, stackTrace) {
      logger.w('打开更新下载失败', error: e, stackTrace: stackTrace);
      await PageUtils.launchURL(_releasePage(release));
    }
  }
}
