import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/common/widgets/pair.dart';
import 'package:pili_aurora/services/diagnostics/redact.dart';
import 'package:pili_aurora/services/settings/webdav_client.dart';
import 'package:pili_aurora/services/settings/webdav_sync.dart';
import 'package:pili_aurora/utils/device_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class WebDav {
  const WebDav();

  Future<WebDavSettingsSync> _sync() async {
    // 同一次操作使用固定配置；下一次操作重新读取，避免旧凭据被缓存。
    final endpoint = Uri.parse(Pref.webdavUri);
    final username = Pref.webdavUsername;
    final password = Pref.webdavPassword;
    final directory = Pref.webdavDirectory;
    var allowInsecureLoopback = false;
    if (WebDavSettingsClient.isLoopbackHttp(endpoint)) {
      final context = Get.context;
      if (context == null ||
          !await showConfirmDialog(
            context: context,
            title: const Text('本次允许本机 WebDAV 明文连接？'),
            content: const Text(
              '仅连接 127.0.0.1 或 ::1。认证信息与备份将以明文传输；'
              '请确认本机服务可信。此授权不会保存。',
            ),
          )) {
        throw StateError('已取消不安全的 WebDAV 连接，请配置 HTTPS');
      }
      allowInsecureLoopback = true;
    }
    final separator = directory.endsWith('/') ? '' : '/';
    return WebDavSettingsSync(
      connect: () => WebDavSettingsClient(
        endpoint: endpoint,
        username: username,
        password: password,
        allowInsecureLoopback: allowInsecureLoopback,
      ),
      directory: '$directory$separator${Constants.appName}',
      fileName:
          '${Constants.dartPackageName}_settings_${DeviceUtils.platformName}.json',
    );
  }

  Future<Pair<bool, String?>> init() async {
    try {
      await (await _sync()).prepare();
      return Pair(first: true, second: null);
    } catch (error) {
      return Pair(first: false, second: DiagnosticRedactor.text(error));
    }
  }

  Future<void> backup() async {
    try {
      await (await _sync()).backup(GStorage.settingsBackup);
      SmartDialog.showToast('备份成功');
    } catch (error) {
      SmartDialog.showToast('备份失败: ${DiagnosticRedactor.text(error)}');
    }
  }

  Future<void> restore() async {
    try {
      await (await _sync()).restore(GStorage.settingsBackup);
      SmartDialog.showToast('恢复成功');
    } catch (error) {
      SmartDialog.showToast('恢复失败: ${DiagnosticRedactor.text(error)}');
    }
  }
}
