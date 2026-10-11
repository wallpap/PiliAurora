import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/login.dart';
import 'package:pili_aurora/pages/login/controller.dart';
import 'package:pili_aurora/pages/setting/models/model.dart';
import 'package:pili_aurora/pages/setting/widgets/multi_select_dialog.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/utils.dart';

List<SettingsModel> get privacySettings => [
  NormalModel(
    onTap: (context, setState) {
      if (!Accounts.main.isLogin) {
        SmartDialog.showToast('登录后查看');
        return;
      }
      Get.toNamed('/blackListPage');
    },
    title: '黑名单管理',
    subtitle: '已拉黑用户',
    leading: const Icon(Icons.block),
  ),
  NormalModel(
    title: '切换账号',
    leading: const Icon(Icons.switch_account_outlined),
    onTap: (context, _) => LoginPageController.switchAccountDialog(context),
  ),
  const NormalModel(
    title: '退出登录',
    leading: Icon(Icons.logout_outlined),
    onTap: _logoutDialog,
  ),
];

Future<LoginAccount?> _logoutWrapper(LoginAccount account) async {
  try {
    final res = await LoginHttp.logout(account);
    return res.isSuccess ? account : null;
  } catch (e, s) {
    Utils.reportError(e, s);
    return null;
  }
}

Future<void> _logoutDialog(BuildContext context, VoidCallback refresh) async {
  if (Accounts.account.isEmpty) {
    SmartDialog.showToast('当前没有已登录账号');
    return;
  }
  final theme = Theme.of(context);
  final result = await showDialog<Set<LoginAccount>>(
    context: context,
    builder: (context) => MultiSelectDialog<LoginAccount>(
      title: '选择要登出的账号uid',
      initValues: const Iterable.empty(),
      values: {
        for (final i in Accounts.account.values) i: i.mid.toString(),
      },
    ),
  );
  if (!context.mounted || result == null || result.isEmpty) return;

  showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('提示'),
        content: Text(
          "确认要退出以下账号登录吗\n\n${result.map((i) => i.mid).join('\n')}",
        ),
        actions: [
          TextButton(
            onPressed: Get.back,
            child: Text(
              '点错了',
              style: TextStyle(color: theme.colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: () async {
              Get.back();
              await Accounts.deleteAll(result);
              refresh();
            },
            child: Text(
              '仅登出',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
          TextButton(
            onPressed: () async {
              SmartDialog.showLoading();
              final res = await Future.wait(result.map(_logoutWrapper));
              SmartDialog.dismiss();
              final logoutAccounts = res.nonNulls.toSet();
              if (logoutAccounts.isEmpty) {
                SmartDialog.showToast('所选账号均退出登录失败');
              } else {
                Get.back();
                await Accounts.deleteAll(logoutAccounts);
                refresh();
                if (logoutAccounts.length != result.length) {
                  result.removeWhere(logoutAccounts.contains);
                  SmartDialog.showToast(
                    '账号 ${result.map((i) => i.mid).join(",")} 退出登录失败',
                  );
                }
              }
            },
            child: const Text('确认'),
          ),
        ],
      );
    },
  );
}
