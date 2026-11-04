import 'dart:convert';

import 'package:pili_aurora/services/settings/settings_backup.dart';
import 'package:pili_aurora/services/settings/webdav_client.dart';

/// 设置快照与 WebDAV 传输的组合，不负责读取全局配置或展示操作结果。
/// 每次操作创建并关闭一个客户端，不跨操作保留认证连接。
class WebDavSettingsSync {
  const WebDavSettingsSync({
    required this._connect,
    required this._directory,
    required this._fileName,
  });

  final WebDavSettingsClient Function() _connect;
  final String _directory;
  final String _fileName;
  String get _path => '$_directory/$_fileName';

  Future<void> prepare() => _withClient(
    (client) => client.ensureDirectory(_directory),
  );

  Future<void> backup(SettingsBackup settings) async {
    // 网络等待前取得内容快照；连接建立期间的本地修改属于下一次备份。
    final bytes = utf8.encode(settings.exportJson());
    await _withClient((client) async {
      await client.ensureDirectory(_directory);
      await client.write(_path, bytes);
    });
  }

  Future<void> restore(SettingsBackup settings) async {
    final bytes = await _withClient((client) => client.read(_path));
    // 下载完成先释放连接，之后才校验/写入本地，不持有闲置网络资源。
    await settings.restoreJson(utf8.decode(bytes));
  }

  Future<T> _withClient<T>(
    Future<T> Function(WebDavSettingsClient client) action,
  ) async {
    final client = _connect();
    try {
      return await action(client);
    } finally {
      client.close();
    }
  }
}
