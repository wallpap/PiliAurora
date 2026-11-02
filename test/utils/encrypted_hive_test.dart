import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as path;
import 'package:pili_aurora/utils/encrypted_hive.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/models/common/account_type.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GStorage.regAdapter();
  late Directory directory;
  late EncryptedHive storage;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('pili-encryption-test-');
    Hive.init(directory.path);
    storage = EncryptedHive(directory.path, List.filled(32, 7));
  });
  tearDown(() async {
    await Hive.close();
    // Hive 的打开失败路径异步关闭文件句柄。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    directory.deleteSync(recursive: true);
  });

  test('迁移旧数据后保留字段、删除明文，后续只使用加密副本', () async {
    final old = await Hive.openBox<dynamic>('account');
    const secret = 'fixture-cookie-and-refresh-token';
    await old.put('42', {
      'cookie': secret,
      'roles': [1, 2],
    });
    await old.close();
    final migrated = await storage.openBox<dynamic>('account');
    expect(migrated.get('42'), {
      'cookie': secret,
      'roles': [1, 2],
    });
    expect(
      File(path.join(directory.path, 'account.hive')).existsSync(),
      isFalse,
    );
    final encrypted = File(migrated.path!).readAsBytesSync();
    expect(latin1.decode(encrypted), isNot(contains(secret)));
    await migrated.put('42', {'cookie': 'new-token'});
    await migrated.close();
    final reopened = await storage.openBox<dynamic>('account');
    expect(reopened.get('42'), {'cookie': 'new-token'});
  });

  test('旧账号适配器迁移后保留 Cookie、双令牌和账号分工', () async {
    final account = LoginAccount(
      BiliCookieJar.fromJson({
        'DedeUserID': '42',
        'SESSDATA': 'fixture-session',
        'bili_jct': 'fixture-csrf',
      }),
      'fixture-access',
      'fixture-refresh',
      {AccountType.main, AccountType.video},
    );
    final old = await Hive.openBox<LoginAccount>('account');
    await old.put('42', account);
    await old.close();
    final migrated = await storage.openBox<LoginAccount>('account');
    final restored = migrated.get('42')!;
    expect(restored.toJson(), account.toJson());
    expect(restored.mid, 42);
    expect(restored.csrf, 'fixture-csrf');
    final bytes = latin1.decode(File(migrated.path!).readAsBytesSync());
    expect(bytes, isNot(contains('fixture-session')));
    expect(bytes, isNot(contains('fixture-access')));
    expect(bytes, isNot(contains('fixture-refresh')));
  });

  test('迁移中断留下的临时文件从旧数据重新生成', () async {
    final old = await Hive.openBox<String>('setting');
    await old.put('password', 'fixture-password');
    await old.close();
    final staging = Directory(
      path.join(directory.path, 'migration_v1', 'setting'),
    )..createSync(recursive: true);
    File(path.join(staging.path, 'setting.hive'))
        .writeAsStringSync('interrupted');
    final migrated = await storage.openBox<String>('setting');
    expect(migrated.get('password'), 'fixture-password');
  });

  test('错误密钥不清空或回退覆盖加密文件', () async {
    final box = await storage.openBox<String>('account');
    await box.put('token', 'fixture-secret');
    final file = File(box.path!);
    await box.close();
    final before = file.readAsBytesSync();
    final wrong = EncryptedHive(directory.path, List.filled(32, 8));
    await expectLater(wrong.openBox<String>('account'), throwsA(anything));
    expect(file.readAsBytesSync(), before);
  });

  test('系统密钥可重用；密钥丢失时保留原加密数据', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final first = await EncryptedHive.initialize(directory.path);
    final box = await first.openBox<String>('account');
    await box.put('token', 'fixture-secret');
    await box.close();
    final second = await EncryptedHive.initialize(directory.path);
    final reopened = await second.openBox<String>('account');
    expect(reopened.get('token'), 'fixture-secret');
    await reopened.close();
    FlutterSecureStorage.setMockInitialValues({});
    await expectLater(
      EncryptedHive.initialize(directory.path),
      throwsStateError,
    );
  });
}
