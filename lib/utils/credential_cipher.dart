import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart';

/// 本机存储和备份共用的凭证加解密格式，兼容旧明文。
abstract final class CredentialCipher {
  static const _prefix = 'piliaurora:credential:v1:';
  // 固定密钥保证跨设备备份可读，修改密钥必须保留旧版本解密能力。
  static final _cipher = Encrypter(
    AES(
      Key.fromBase64('sY4g+1pxR0a9wLFk7hKe2uC5mZ8NvD3qT6bXoA0jEiU='),
      mode: AESMode.gcm,
    ),
  );

  static String? encrypt(String? value) {
    if (value == null || value.isEmpty) return value;
    final iv = IV.fromSecureRandom(12);
    final encrypted = _cipher.encrypt(value, iv: iv);
    return '$_prefix${base64Encode([...iv.bytes, ...encrypted.bytes])}';
  }

  /// 无版本标记的旧明文直接读取；损坏的密文不能回退成凭证使用。
  static String? decrypt(String? value) {
    if (value == null || !value.startsWith('piliaurora:credential:')) {
      return value;
    }
    if (!value.startsWith(_prefix)) {
      throw const FormatException('不支持的凭证密文版本');
    }
    try {
      final bytes = base64Decode(value.substring(_prefix.length));
      if (bytes.length < 28) throw const FormatException();
      return _cipher.decrypt(
        Encrypted(Uint8List.sublistView(bytes, 12)),
        iv: IV(Uint8List.sublistView(bytes, 0, 12)),
      );
    } catch (_) {
      throw const FormatException('凭证密文损坏或版本不兼容');
    }
  }

  /// 校验已有密文或将旧明文升级，避免备份与存储反复加密。
  static String? normalize(String? value) {
    final plain = decrypt(value);
    return plain == value ? encrypt(value) : value;
  }
}
