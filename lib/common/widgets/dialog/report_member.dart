import 'package:pili_aurora/common/widgets/button/icon_button.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/member.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/extension/theme_ext.dart';
import 'package:pili_aurora/utils/theme_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart';

const _reason = ['头像违规', '昵称违规', '签名违规'];

const _reasonV2 = ['色情低俗', '不实信息', '违禁', '人身攻击', '赌博诈骗', '违规引流外链'];

Future<void> showMemberReportDialog(
  BuildContext context, {
  required Object? name,
  required Object mid,
}) {
  final Set<int> reason = {};
  int? reasonV2;
  var submitting = false;
  final account = Accounts.main;
  bool current() => context.mounted && identical(account, Accounts.main);

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        final theme = Theme.of(context);
        return AlertDialog(
          clipBehavior: Clip.hardEdge,
          contentPadding: const EdgeInsets.symmetric(vertical: 16),
          titleTextStyle: theme.textTheme.bodyMedium,
          title: Row(
            crossAxisAlignment: .start,
            children: [
              Expanded(
                child: Column(
                  spacing: 4,
                  crossAxisAlignment: .start,
                  children: [
                    Text(
                      '举报: $name',
                      style: const TextStyle(fontSize: 18),
                    ),
                    Text('uid: $mid'),
                  ],
                ),
              ),
              iconButton(
                iconSize: 21,
                tooltip: '网页举报',
                onPressed: submitting
                    ? null
                    : () => Get.toNamed(
                        '/webview',
                        parameters: {
                          'url':
                              'https://account.bilibili.com/h5/account-h5/gr/report?navhide=1&targetmid=$mid&${ThemeUtils.themeUrl(theme.isDark)}',
                        },
                      ),
                icon: const Icon(MdiIcons.web),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: .min,
              crossAxisAlignment: .start,
              children: [
                const Padding(
                  padding: .only(left: 18),
                  child: Text('举报内容（必选，可多选）'),
                ),
                ...List.generate(
                  3,
                  (index) => Builder(
                    builder: (context) {
                      final checked = reason.contains(index + 1);
                      return ListTile(
                        dense: true,
                        minTileHeight: 40,
                        onTap: submitting
                            ? null
                            : () => setState(() {
                                if (!checked) {
                                  reason.add(index + 1);
                                } else {
                                  reason.remove(index + 1);
                                }
                              }),
                        title: Row(
                          spacing: 8,
                          children: [
                            checked
                                ? Icon(
                                    size: 22,
                                    Icons.check_box,
                                    color: theme.colorScheme.primary,
                                  )
                                : Icon(
                                    size: 22,
                                    Icons.check_box_outline_blank,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                            Expanded(
                              child: Text(
                                _reason[index],
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const Padding(
                  padding: .only(left: 18),
                  child: Text('举报理由（单选，非必选）'),
                ),
                Builder(
                  builder: (context) => Column(
                    crossAxisAlignment: .start,
                    children: List.generate(
                      _reasonV2.length,
                      (index) {
                        final checked = index == reasonV2;
                        return ListTile(
                          dense: true,
                          minTileHeight: 40,
                          onTap: submitting
                              ? null
                              : () => setState(() {
                                  if (checked) {
                                    reasonV2 = null;
                                  } else {
                                    reasonV2 = index;
                                  }
                                }),
                          title: Row(
                            spacing: 8,
                            children: [
                              checked
                                  ? Icon(
                                      size: 22,
                                      Icons.radio_button_checked,
                                      color: theme.colorScheme.primary,
                                    )
                                  : Icon(
                                      size: 22,
                                      Icons.radio_button_off,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                              Expanded(
                                child: Text(
                                  _reasonV2[index],
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(
                '取消',
                style: TextStyle(color: theme.colorScheme.outline),
              ),
            ),
            TextButton(
              onPressed: submitting
                  ? null
                  : () async {
                      if (submitting) return;
                      if (!current()) {
                        SmartDialog.showToast('账号已切换，请重新打开举报');
                        return;
                      }
                      if (reason.isEmpty) {
                        SmartDialog.showToast('至少选择一项作为举报内容');
                        return;
                      }
                      final route = ModalRoute.of(dialogContext);
                      setState(() => submitting = true);
                      try {
                        final result = await MemberHttp.reportMember(
                          mid,
                          account: account,
                          reason: reason.join(','),
                          reasonV2: reasonV2 != null ? reasonV2! + 1 : null,
                        );
                        if (!current() ||
                            !dialogContext.mounted ||
                            route?.isCurrent != true) {
                          return;
                        }
                        if (result.isSuccess) {
                          Navigator.of(dialogContext).pop();
                          SmartDialog.showToast('举报成功');
                        } else {
                          result.toast();
                        }
                      } catch (error, stackTrace) {
                        final failure = UnknownResult(
                          cause: error,
                          stackTrace: stackTrace,
                        );
                        if (current() &&
                            dialogContext.mounted &&
                            route?.isCurrent == true) {
                          failure.toast();
                        }
                      } finally {
                        if (context.mounted) setState(() => submitting = false);
                      }
                    },
              child: Text(submitting ? '提交中' : '确定'),
            ),
          ],
        );
      },
    ),
  );
}
