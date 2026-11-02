import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/settings/backup_cipher.dart';

void main() {
  const password = 'fixture-password';
  const source = '{"42":{"cookies":"fixture-secret","refresh":"令牌"}}';
  test('密码加密备份可跨设备恢复原始全部字段，每次使用不同盐和随机数', () async {
    final first = await BackupCipher.encrypt(source, password, '登录信息');
    final second = await BackupCipher.encrypt(source, password, '登录信息');
    expect(first, isNot(second));
    expect(first, isNot(contains('fixture-secret')));
    expect(
      await BackupCipher.decrypt(jsonDecode(first) as Map, password, '登录信息'),
      jsonDecode(source),
    );
    expect(BackupCipher.isEncrypted(jsonDecode(source)), isFalse);
  });
  test('错误密码、篡改和类型不匹配均拒绝恢复', () async {
    final envelope =
        jsonDecode(await BackupCipher.encrypt(source, password, '登录信息')) as Map;
    await expectLater(
      BackupCipher.decrypt(envelope, 'wrong-password', '登录信息'),
      throwsFormatException,
    );
    await expectLater(
      BackupCipher.decrypt(envelope, password, '设置'),
      throwsFormatException,
    );
    final bytes = base64Decode(envelope['data'] as String)..[0] ^= 1;
    envelope['data'] = base64Encode(bytes);
    await expectLater(
      BackupCipher.decrypt(envelope, password, '登录信息'),
      throwsFormatException,
    );
  });
}
