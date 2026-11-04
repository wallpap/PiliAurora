import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/accounts/account_adapter.dart';
import 'package:pili_aurora/utils/storage.dart';

// 保留旧磁盘格式作为升级夹具。
class _LegacyAdapter extends LoginAccountAdapter {
  @override
  void write(BinaryWriter writer, LoginAccount obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.cookieJar)
      ..writeByte(1)
      ..write(obj.accessKey)
      ..writeByte(2)
      ..write(obj.refresh)
      ..writeByte(3)
      ..write(obj.type.toList());
  }
}

void main() {
  final legacy = {
    'cookies': {
      'DedeUserID': '123',
      'bili_jct': 'fixture-csrf-secret',
      'SESSDATA': 'fixture-session-secret',
    },
    'accessKey': 'fixture-access-secret',
    'refresh': 'fixture-refresh-secret',
    'type': [0],
  };

  test('new JSON hides credentials and both JSON formats import', () {
    final account = LoginAccount.fromJson(legacy);
    final exported = jsonEncode(account);
    expect(exported, isNot(contains('fixture-')));
    final restored = LoginAccount.fromJson(jsonDecode(exported));
    expect(restored.mid, account.mid);
    expect(restored.cookieJar.toJson(), account.cookieJar.toJson());
    expect(restored.accessKey, account.accessKey);
    expect(restored.refresh, account.refresh);
    expect(restored.type, account.type);
  });

  test(
    'upgrades a plaintext Hive file and reads encrypted snapshots',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'credential-test-',
      );
      try {
        Hive.init(directory.path);
        GStorage.regAdapter();
        Hive.registerAdapter<LoginAccount>(_LegacyAdapter(), override: true);
        final old = await Hive.openBox<LoginAccount>('account');
        await old.put('123', LoginAccount.fromJson(legacy));
        final file = File(old.path!);
        await old.close();
        expect(latin1.decode(await file.readAsBytes()), contains('fixture-'));

        Hive.registerAdapter<LoginAccount>(
          LoginAccountAdapter(),
          override: true,
        );
        await Accounts.init();
        expect(Accounts.account.get('123')!.refresh, legacy['refresh']);
        await Accounts.account.flush();
        final snapshot = await file.readAsBytes();
        expect(latin1.decode(snapshot), isNot(contains('fixture-')));
        await Accounts.account.close();

        final memory = await Hive.openBox<LoginAccount>(
          'snapshot',
          bytes: snapshot,
        );
        expect(memory.get('123')!.accessKey, legacy['accessKey']);
        expect(memory.get('123')!.csrf, 'fixture-csrf-secret');
        await memory.close();
      } finally {
        await Hive.close();
        Hive.resetAdapters();
        await directory.delete(recursive: true);
      }
    },
  );
}
