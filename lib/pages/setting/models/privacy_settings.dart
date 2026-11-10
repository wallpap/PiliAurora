import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/http/login.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/login/controller.dart';
import 'package:pili_aurora/pages/setting/models/model.dart';
import 'package:pili_aurora/pages/setting/widgets/multi_select_dialog.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/storage_key.dart';

List<SettingsModel> get privacySettings => [
  const SwitchModel(
    title: '增强黑名单屏蔽',
    subtitle: '信息流中过滤已拉黑作者的视频、专栏、动态和直播，并继续加载内容补位；刷新后生效',
    leading: Icon(Icons.hide_source_outlined),
    setKey: SettingBoxKey.filterBlockedAuthors,
    defaultVal: true,
    children: [
      SwitchModel(
        title: '检查合作视频作者',
        subtitle: '对列表标明的合作视频补查作者，任一作者被拉黑即屏蔽；会增加请求和加载时间，结果会缓存；刷新后生效',
        leading: Icon(Icons.group_outlined),
        setKey: SettingBoxKey.checkCooperativeAuthors,
        defaultVal: true,
      ),
    ],
  ),
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

bool _isStoredLogin(LoginAccount account) =>
    Accounts.account.values.any((value) => identical(value, account));

Future<LoadingState<void>> _logoutWrapper(LoginAccount account) async {
  if (!_isStoredLogin(account)) {
    return const Error('登录信息已更新，请重新选择');
  }
  try {
    return await LoginHttp.logout(account);
  } catch (error, stackTrace) {
    logger.w('退出登录请求失败', error: error.runtimeType, stackTrace: stackTrace);
    return UnknownResult(cause: error, stackTrace: stackTrace);
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

  var submitting = false;
  final confirmed = Set<LoginAccount>.identity();
  final messages = <LoginAccount, String>{};
  String? cleanupWarning;

  Future<void> cleanup(Set<LoginAccount> accounts) async {
    // LoginAccount 按 mid 相等；旧凭据的回执不能删除同 mid 的新登录。
    final current = <LoginAccount>{};
    for (final account in accounts) {
      if (_isStoredLogin(account)) {
        current.add(account);
      } else {
        messages[account] = confirmed.contains(account)
            ? '远端已退出，登录信息已更新，请核对'
            : '登录信息已更新，请重新选择';
      }
    }
    if (current.isEmpty) return;
    try {
      await Accounts.deleteAll(current);
    } catch (error, stackTrace) {
      logger.w(
        '退出登录后的本地清理失败',
        error: error.runtimeType,
        stackTrace: stackTrace,
      );
      cleanupWarning = '账号已登出，部分本地清理失败，请重启后核对';
    }
    for (final account in current) {
      final remaining = Accounts.account.values.where(
        (a) => a.mid == account.mid,
      );
      if (remaining.isEmpty) {
        result.remove(account);
        messages.remove(account);
      } else if (remaining.any((a) => identical(a, account))) {
        messages[account] = confirmed.contains(account)
            ? '远端已退出，本地清理失败；再次确认将仅重试清理'
            : '本地清理失败，请重试';
      } else {
        messages[account] = confirmed.contains(account)
            ? '远端已退出，登录信息已更新，请核对'
            : '登录信息已更新，请重新选择';
      }
    }
    if (context.mounted) {
      try {
        refresh();
      } catch (error, stackTrace) {
        logger.w(
          '退出登录后的页面刷新失败',
          error: error.runtimeType,
          stackTrace: stackTrace,
        );
      }
    }
  }

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        Future<void> submit({required bool revoke}) async {
          final route = ModalRoute.of(dialogContext);
          if (submitting || route?.isCurrent != true) return;
          setState(() => submitting = true);
          cleanupWarning = null;
          try {
            if (revoke) {
              final targets = result
                  .where((a) => !confirmed.contains(a))
                  .toList();
              final outcomes = await Future.wait(targets.map(_logoutWrapper));
              for (var i = 0; i < targets.length; i++) {
                final account = targets[i];
                final outcome = outcomes[i];
                if (outcome.isSuccess) {
                  confirmed.add(account);
                  messages.remove(account);
                } else {
                  messages[account] = outcome.toString();
                }
              }
              await cleanup(result.where(confirmed.contains).toSet());
            } else {
              await cleanup(Set.of(result));
            }
            if (!dialogContext.mounted || route?.isCurrent != true) return;
            if (result.isEmpty) {
              Navigator.of(dialogContext).pop();
              SmartDialog.showToast(cleanupWarning ?? '所选账号已退出登录');
            }
          } catch (error, stackTrace) {
            logger.w(
              '退出登录处理失败',
              error: error.runtimeType,
              stackTrace: stackTrace,
            );
            if (dialogContext.mounted && route?.isCurrent == true) {
              SmartDialog.showToast('本地处理失败，请核对账号状态后重试');
            }
          } finally {
            if (context.mounted) setState(() => submitting = false);
          }
        }

        return AlertDialog(
          title: const Text('提示'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('确认要退出以下账号登录吗'),
                for (final account in result)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      ['${account.mid}', ?messages[account]].join('\n'),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(
                '点错了',
                style: TextStyle(color: theme.colorScheme.outline),
              ),
            ),
            TextButton(
              onPressed: submitting ? null : () => submit(revoke: false),
              child: Text(
                '仅登出',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
            TextButton(
              onPressed: submitting ? null : () => submit(revoke: true),
              child: Text(submitting ? '处理中' : '确认'),
            ),
          ],
        );
      },
    ),
  );
}
