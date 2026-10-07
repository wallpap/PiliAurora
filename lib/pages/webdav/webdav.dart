import 'dart:convert';

import 'package:pili_aurora/common/constants.dart';
import 'package:pili_aurora/common/widgets/pair.dart';
import 'package:pili_aurora/utils/device_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:pili_aurora/services/settings/webdav_client.dart';
import 'package:pili_aurora/services/diagnostics/redact.dart';

typedef _WebDavConfig = ({
  String uri,
  String username,
  String password,
  String directory,
});

class WebDav {
  const WebDav();

  _WebDavConfig _getConfig() {
    String directory = Pref.webdavDirectory;
    if (!directory.endsWith('/')) {
      directory += '/';
    }
    return (
      uri: Pref.webdavUri,
      username: Pref.webdavUsername,
      password: Pref.webdavPassword,
      directory: '$directory${Constants.appName}',
    );
  }

  Future<T> _withClient<T>(
    _WebDavConfig config,
    Future<T> Function(WebDavSettingsClient client) action,
  ) async {
    final client = WebDavSettingsClient(
      endpoint: Uri.parse(config.uri),
      username: config.username,
      password: config.password,
    );
    try {
      return await action(client);
    } finally {
      client.close();
    }
  }

  Future<Pair<bool, String?>> init() async {
    try {
      final config = _getConfig();
      await _withClient(
        config,
        (client) => client.ensureDirectory(config.directory),
      );

      return Pair(first: true, second: null);
    } catch (e) {
      return Pair(first: false, second: DiagnosticRedactor.text(e));
    }
  }

  String _getFileName() {
    return '${Constants.dartPackageName}_settings_${DeviceUtils.platformName}.json';
  }

  Future<void> backup() async {
    // 连接配置和内容都取自同一个操作快照，不跨操作缓存含凭据的客户端。
    final config = _getConfig();
    final data = GStorage.exportAllSettings();
    try {
      await _withClient(config, (client) async {
        await client.ensureDirectory(config.directory);
        await client.write(
          '${config.directory}/${_getFileName()}',
          utf8.encode(data),
        );
      });
      SmartDialog.showToast('备份成功');
    } catch (e) {
      SmartDialog.showToast('备份失败: ${DiagnosticRedactor.text(e)}');
    }
  }

  Future<void> restore() async {
    final config = _getConfig();
    try {
      final data = await _withClient(
        config,
        (client) => client.read('${config.directory}/${_getFileName()}'),
      );
      await GStorage.importAllSettings(utf8.decode(data));
      SmartDialog.showToast('恢复成功');
    } catch (e) {
      SmartDialog.showToast('恢复失败: ${DiagnosticRedactor.text(e)}');
    }
  }
}
