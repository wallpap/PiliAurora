import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/pages/mine/controller.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/accounts/account_adapter.dart';
import 'package:pili_aurora/utils/login_utils.dart';
import 'package:pili_aurora/services/messaging/session.dart';
import 'package:hive_ce/hive.dart';

abstract final class Accounts {
  static late final Box<LoginAccount> account;
  static final List<Account> accountMode = List.filled(
    AccountType.values.length,
    AnonymousAccount(),
  );
  static bool get mainEqVideo => main == video;
  static Account get main => accountMode[AccountType.main.index];
  static final _mainChanges = ValueNotifier(0);
  static ValueListenable<int> get mainChanges => _mainChanges;

  static void _onMainChanged() {
    Messaging.onAccountChanged();
    _mainChanges.value++;
  }

  static Account get video => accountMode[AccountType.video.index];
  static Account get heartbeat => accountMode[AccountType.heartbeat.index];
  static Account get history {
    final heartbeat = Accounts.heartbeat;
    if (heartbeat is AnonymousAccount) {
      return Accounts.main;
    }
    return heartbeat;
  }

  /// 重新登录也会替换账号对象，使使用旧凭据的在途结果失效。
  static void replaceCredentials(LoginAccount account) {
    final previousMain = main;
    for (final type in AccountType.values) {
      if (accountMode[type.index].mid == account.mid) {
        accountMode[type.index] = account;
        account.type.add(type);
      }
    }
    if (!identical(previousMain, main)) _onMainChanged();
  }
  // static set main(Account account) => set(AccountType.main, account);

  static Future<void> init({Uint8List? bytes}) async {
    LoginAccountAdapter.readLegacy = false;
    account = await Hive.openBox(
      'account',
      bytes: bytes,
      compactionStrategy: (int entries, int deletedEntries) {
        return deletedEntries > 2;
      },
    );
    if (bytes == null && LoginAccountAdapter.readLegacy) {
      // 成功重写后压缩，清除文件中旧的明文记录；子进程快照只读。
      await account.putAll(account.toMap());
      await account.compact();
    }
  }

  static Future<void> refresh() {
    for (final a in account.values) {
      for (final t in a.type) {
        accountMode[t.index] = a;
      }
    }
    _onMainChanged();
    return Future.wait(
      (accountMode.toSet()..removeWhere((i) => i.activated)).map(
        Request.buvidActive,
      ),
    );
  }

  static Future<void> clear() async {
    await account.clear();
    for (int i = 0; i < AccountType.values.length; i++) {
      accountMode[i] = AnonymousAccount();
    }
    _onMainChanged();
    await AnonymousAccount().delete();
    Request.buvidActive(AnonymousAccount());
  }

  static Future<void> deleteAll(Set<Account> accounts) async {
    final previousMain = Accounts.main;
    final isLoginMain = previousMain.isLogin;
    for (int i = 0; i < AccountType.values.length; i++) {
      if (accounts.contains(accountMode[i])) {
        accountMode[i] = AnonymousAccount();
      }
    }
    if (!identical(previousMain, Accounts.main)) {
      _onMainChanged();
    }
    await Future.wait(accounts.map((i) => i.delete()));
    if (isLoginMain && !Accounts.main.isLogin) {
      await LoginUtils.onLogoutMain();
    }
  }

  static Future<void> set(AccountType key, Account account) async {
    final oldAccount = accountMode[key.index]..type.remove(key);
    accountMode[key.index] = account..type.add(key);
    if (key == AccountType.main) _onMainChanged();
    await Future.wait([?account.onChange(), ?oldAccount.onChange()]);
    if (!account.activated) await Request.buvidActive(account);
    switch (key) {
      case AccountType.main:
        await (account.isLogin
            ? LoginUtils.onLoginMain()
            : LoginUtils.onLogoutMain());
        break;
      case AccountType.heartbeat:
        MineController.anonymity.value = !account.isLogin;
        break;
      default:
        break;
    }
  }

  @pragma("vm:prefer-inline")
  static Account get(AccountType key) {
    return accountMode[key.index];
  }
}
