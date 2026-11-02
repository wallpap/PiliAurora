import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as path;

/// 密钥由系统保管；旧 Box 只在加密副本落盘并重新打开后删除。
class EncryptedHive {
  EncryptedHive(this.root, List<int> key) : cipher = HiveAesCipher(key);

  final String root;
  final HiveAesCipher cipher;
  String get encryptedPath => path.join(root, 'encrypted_v1');
  static const _keyName = 'piliaurora_hive_key_v1';
  static const _vault = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );

  static Future<EncryptedHive> initialize(String root) async {
    var encoded = await _vault.read(key: _keyName);
    if (encoded == null) {
      // 丢失密钥时不生成新密钥覆盖已有加密数据。
      if (Directory(path.join(root, 'encrypted_v1')).existsSync()) {
        throw StateError('本地数据密钥不可用，请恢复原系统安全存储。');
      }
      encoded = base64Encode(Hive.generateSecureKey());
      await _vault.write(key: _keyName, value: encoded);
      if (await _vault.read(key: _keyName) != encoded) {
        throw StateError('无法保存本地数据密钥');
      }
    }
    List<int> key;
    try {
      key = base64Decode(encoded);
      if (key.length != 32) throw const FormatException();
    } on FormatException {
      throw StateError('本地数据密钥无效');
    }
    return EncryptedHive(root, key);
  }

  Future<Box<T>> openBox<T>(String name, {Uint8List? bytes}) async {
    if (bytes != null) {
      return Hive.openBox<T>(name, bytes: bytes, encryptionCipher: cipher);
    }
    name = name.toLowerCase();
    final target = File(path.join(encryptedPath, '$name.hive'));
    if (!target.existsSync() &&
        !File(path.join(encryptedPath, '$name.hivec')).existsSync() &&
        await Hive.boxExists(name, path: root)) {
      final legacy = await Hive.openBox<T>(
        name,
        path: root,
        crashRecovery: false,
      );
      final values = legacy.toMap();
      await legacy.close();
      // 中断的临时副本可直接重建，原文件在迁移成功前始终保留。
      final staging = path.join(root, 'migration_v1', name);
      await Hive.deleteBoxFromDisk(name, path: staging);
      final copy = await Hive.openBox<T>(
        name,
        path: staging,
        encryptionCipher: cipher,
        crashRecovery: false,
      );
      try {
        await copy.putAll(values);
        await copy.flush();
      } finally {
        await copy.close();
      }
      final verified = await Hive.openBox<T>(
        name,
        path: staging,
        encryptionCipher: cipher,
        crashRecovery: false,
      );
      try {
        if (verified.length != values.length ||
            values.keys.any((key) => !verified.containsKey(key))) {
          throw StateError('本地数据迁移校验失败');
        }
      } finally {
        await verified.close();
      }
      await Directory(encryptedPath).create(recursive: true);
      await File(path.join(staging, '$name.hive')).rename(target.path);
      await Hive.deleteBoxFromDisk(name, path: staging);
    }
    final box = await Hive.openBox<T>(
      name,
      path: encryptedPath,
      encryptionCipher: cipher,
      crashRecovery: false,
    );
    // 不调用 Hive.deleteBoxFromDisk：同名加密 Box 此时已打开。
    for (final extension in ['hive', 'hivec', 'lock']) {
      final legacy = File(path.join(root, '$name.$extension'));
      if (legacy.existsSync()) await legacy.delete();
    }
    return box;
  }
}
