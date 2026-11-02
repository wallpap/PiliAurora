import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:pointycastle/export.dart';

/// 可移植备份使用密码派生密钥，不导出本机的存储密钥。
abstract final class BackupCipher {
  static const format = 'piliaurora-encrypted-backup';
  static const _iterations = 210000;

  static bool isEncrypted(Object? value) =>
      value is Map && value['format'] == format;

  static enc.Encrypter _cipher(String password, Uint8List salt) {
    final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, _iterations, 32));
    final key = kdf.process(Uint8List.fromList(utf8.encode(password)));
    return enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.gcm));
  }

  static Future<String> encrypt(String json, String password, String kind) =>
      Isolate.run(() {
        if (password.length < 8) throw ArgumentError('备份密码至少需要 8 个字符');
        final salt = enc.IV.fromSecureRandom(16);
        final nonce = enc.IV.fromSecureRandom(12);
        final encrypted = _cipher(password, salt.bytes).encrypt(
          json,
          iv: nonce,
          associatedData: Uint8List.fromList(utf8.encode('$format:1:$kind')),
        );
        return jsonEncode({
          'format': format,
          'version': 1,
          'kind': kind,
          'salt': salt.base64,
          'nonce': nonce.base64,
          'data': encrypted.base64,
        });
      });

  static Future<dynamic> decrypt(Map envelope, String password, String kind) =>
      Isolate.run(() {
        if (envelope['version'] != 1 || envelope['kind'] != kind) {
          throw const FormatException('备份版本或类型不匹配');
        }
        try {
          final salt = base64Decode(envelope['salt'] as String);
          final nonce = base64Decode(envelope['nonce'] as String);
          if (salt.length != 16 || nonce.length != 12) {
            throw const FormatException();
          }
          final json = _cipher(password, salt).decrypt(
            enc.Encrypted.fromBase64(envelope['data'] as String),
            iv: enc.IV(nonce),
            associatedData: Uint8List.fromList(utf8.encode('$format:1:$kind')),
          );
          return jsonDecode(json);
        } catch (_) {
          throw const FormatException('备份密码错误或文件已损坏');
        }
      });
}
