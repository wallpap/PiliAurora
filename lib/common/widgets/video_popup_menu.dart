import 'package:pili_aurora/utils/request_utils.dart';
import 'package:pili_aurora/common/widgets/app_popup_menu_item.dart';
import 'package:pili_aurora/common/widgets/custom_icon.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/home/rcmd/result.dart';
import 'package:pili_aurora/models/model_video.dart';
import 'package:pili_aurora/models/remote/space/space_archive/item.dart';
import 'package:pili_aurora/pages/mine/controller.dart';
import 'package:pili_aurora/common/widgets/dialog/video_feedback.dart';
import 'package:pili_aurora/pages/video/ai_conclusion/view.dart';
import 'package:pili_aurora/pages/video/introduction/ugc/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart';

class _VideoCustomAction {
  final String title;
  final Widget icon;
  final VoidCallback onTap;
  const _VideoCustomAction(this.title, this.icon, this.onTap);
}

class VideoPopupMenu extends StatefulWidget {
  final double? iconSize;
  final double menuItemHeight;
  final BaseSimpleVideoItemModel videoItem;
  final VoidCallback? onRemove;

  const VideoPopupMenu({
    super.key,
    required this.iconSize,
    required this.videoItem,
    this.onRemove,
    this.menuItemHeight = 45,
  });

  @override
  State<VideoPopupMenu> createState() => _VideoPopupMenuState();
}

class _VideoPopupMenuState extends State<VideoPopupMenu> {
  void _showFeedback(BaseSimpleVideoItemModel item, VoidCallback? onRemove) {
    if (!mounted || !identical(item, widget.videoItem)) return;
    final account = item is RcmdVideoItemAppModel
        ? Accounts.get(.recommend)
        : Accounts.main;
    if (account.accessKey?.isNotEmpty != true) {
      SmartDialog.showToast(account.isLogin ? '请退出账号后重新登录' : '账号未登录');
      return;
    }
    showDialog<void>(
      context: context,
      builder: (_) => VideoFeedbackDialog(
        item: item,
        isCurrent: () =>
            mounted &&
            identical(item, widget.videoItem) &&
            identical(
              account,
              item is RcmdVideoItemAppModel
                  ? Accounts.get(.recommend)
                  : Accounts.main,
            ),
        onRemove: onRemove,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final iconSize = widget.iconSize;
    final menuItemHeight = widget.menuItemHeight;
    final videoItem = widget.videoItem;
    final onRemove = widget.onRemove;
    return PopupMenuButton(
      padding: EdgeInsets.zero,
      icon: Icon(
        Icons.more_vert_outlined,
        color: Theme.of(context).colorScheme.outline,
        size: iconSize,
      ),
      position: PopupMenuPosition.under,
      itemBuilder: (context) =>
          [
                if (videoItem.bvid?.isNotEmpty == true) ...[
                  _VideoCustomAction(
                    videoItem.bvid!,
                    const Icon(CustomIcons.identifier_circle, size: 16),
                    () => Utils.copyText(videoItem.bvid!),
                  ),
                  if (Accounts.main.isLogin)
                    _VideoCustomAction(
                      '稍后再看',
                      const Icon(MdiIcons.clockTimeEightOutline, size: 16),
                      () => RequestUtils.addToWatchLater(bvid: videoItem.bvid),
                    ),
                  if (videoItem.cid != null && Pref.enableAi)
                    _VideoCustomAction(
                      'AI总结',
                      const Icon(CustomIcons.ai_circle, size: 16),
                      () async {
                        final res = await UgcIntroController.getAiConclusion(
                          videoItem.bvid!,
                          videoItem.cid!,
                          videoItem.owner.mid,
                        );
                        if (res != null && context.mounted) {
                          showDialog(
                            context: context,
                            builder: (context) => Dialog(
                              child: Padding(
                                padding: const .symmetric(vertical: 14),
                                child: AiConclusionPanel.buildContent(
                                  context,
                                  Theme.of(context),
                                  res,
                                  tap: false,
                                ),
                              ),
                            ),
                          );
                        }
                      },
                    ),
                ],
                if (videoItem is! SpaceArchiveItem) ...[
                  _VideoCustomAction(
                    '访问：${videoItem.owner.name}',
                    const Icon(MdiIcons.accountCircleOutline, size: 16),
                    () => Get.toNamed('/member?mid=${videoItem.owner.mid}'),
                  ),
                  _VideoCustomAction(
                    '不感兴趣',
                    const Icon(MdiIcons.thumbDownOutline, size: 16),
                    () => _showFeedback(videoItem, onRemove),
                  ),
                  _VideoCustomAction(
                    '拉黑：${videoItem.owner.name}',
                    const Icon(MdiIcons.cancel, size: 16),
                    () => showDialog(
                      context: context,
                      builder: (context) {
                        return AlertDialog(
                          title: const Text('提示'),
                          content: Text(
                            '确定拉黑:${videoItem.owner.name}(${videoItem.owner.mid})?'
                            '\n\n注：被拉黑的Up可以在隐私设置-黑名单管理中解除',
                          ),
                          actions: [
                            TextButton(
                              onPressed: Get.back,
                              child: Text(
                                '点错了',
                                style: TextStyle(
                                  color: ColorScheme.of(context).outline,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () async {
                                Get.back();
                                final res = await VideoHttp.relationMod(
                                  mid: videoItem.owner.mid!,
                                  act: 5,
                                  reSrc: 11,
                                );
                                if (res.isSuccess) {
                                  onRemove?.call();
                                } else {
                                  res.toast();
                                }
                              },
                              child: const Text('确认'),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
                _VideoCustomAction(
                  "${MineController.anonymity.value ? '退出' : '进入'}无痕模式",
                  MineController.anonymity.value
                      ? const Icon(MdiIcons.incognitoOff, size: 16)
                      : const Icon(MdiIcons.incognito, size: 16),
                  MineController.onChangeAnonymity,
                ),
              ]
              .map(
                (e) => AppPopupMenuItem(
                  height: menuItemHeight,
                  onTap: e.onTap,
                  child: Row(
                    children: [
                      e.icon,
                      const SizedBox(width: 6),
                      Text(e.title, style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
              )
              .toList(),
    );
  }
}
