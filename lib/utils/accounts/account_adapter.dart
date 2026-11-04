import 'dart:convert';

import 'package:pili_aurora/utils/credential_cipher.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:hive_ce/hive.dart';

class LoginAccountAdapter extends TypeAdapter<LoginAccount> {
  static bool readLegacy = false;

  @override
  final int typeId = 9;

  @override
  LoginAccount read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    final cookies = fields[0];
    if (cookies is! String) readLegacy = true;
    return LoginAccount(
      cookies is String
          ? BiliCookieJar.fromJson(
              jsonDecode(CredentialCipher.decrypt(cookies)!),
            )
          : cookies as DefaultCookieJar,
      CredentialCipher.decrypt(fields[1] as String?),
      CredentialCipher.decrypt(fields[2] as String?),
      (fields[3] as List?)?.cast<AccountType>().toSet(),
    );
  }

  @override
  void write(BinaryWriter writer, LoginAccount obj) {
    final credentials = obj.toJson()!;
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(credentials['cookies'])
      ..writeByte(1)
      ..write(credentials['accessKey'])
      ..writeByte(2)
      ..write(credentials['refresh'])
      ..writeByte(3)
      ..write(obj.type.toList());
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LoginAccountAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
