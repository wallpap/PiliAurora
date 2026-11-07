import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

/// 按账号对象身份发布切换，登录账号之间切换也会使依赖状态重建。
final mainAccountProvider = NotifierProvider<MainAccountNotifier, Account>(
  MainAccountNotifier.new,
  isAutoDispose: true,
);

class MainAccountNotifier extends Notifier<Account> {
  @override
  Account build() {
    final accounts = Accounts.mainChanges;
    void changed() => state = Accounts.main;
    accounts.addListener(changed);
    ref.onDispose(() => accounts.removeListener(changed));
    return Accounts.main;
  }

  // 同一 mid 的新凭据也是独立账号对象，不能沿用 Account 的值相等语义。
  @override
  bool updateShouldNotify(Account previous, Account next) =>
      !identical(previous, next);
}
