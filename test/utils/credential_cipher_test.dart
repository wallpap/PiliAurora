import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/utils/credential_cipher.dart';

void main() {
  test('round trips Unicode with a fresh nonce on every write', () {
    const plain = '测试凭证🔐';
    final first = CredentialCipher.encrypt(plain)!;
    expect(first, isNot(contains(plain)));
    expect(CredentialCipher.decrypt(first), plain);
    expect(CredentialCipher.encrypt(plain), isNot(first));
    expect(CredentialCipher.normalize(first), first);
  });

  test('legacy plaintext, null and empty values remain readable', () {
    for (final value in [null, '', 'legacy-token']) {
      expect(CredentialCipher.decrypt(value), value);
      expect(
        CredentialCipher.decrypt(CredentialCipher.normalize(value)),
        value,
      );
    }
  });

  test('rejects malformed and tampered ciphertext', () {
    final encrypted = CredentialCipher.encrypt('token')!;
    final split = encrypted.lastIndexOf(':') + 1;
    final bytes = base64Decode(encrypted.substring(split))..last ^= 1;
    final tampered = encrypted.substring(0, split) + base64Encode(bytes);
    expect(() => CredentialCipher.decrypt(tampered), throwsFormatException);
    expect(
      () => CredentialCipher.decrypt('${encrypted.substring(0, split)}bad'),
      throwsFormatException,
    );
    expect(
      () => CredentialCipher.decrypt(encrypted.replaceFirst(':v1:', ':v2:')),
      throwsFormatException,
    );
  });
}
