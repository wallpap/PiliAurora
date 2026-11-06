import 'package:pili_aurora/common/widgets/app_popup_menu_item.dart';
import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/common/widgets/badge.dart';
import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/common/widgets/dialog/simple_dialog_option.dart';
import 'package:pili_aurora/common/widgets/flutter/list_tile.dart';
import 'package:pili_aurora/common/widgets/pendant_avatar.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/whisper_secondary/view.dart';
import 'package:pili_aurora/services/messaging/session_models.dart';
import 'package:pili_aurora/utils/date_utils.dart';
import 'package:pili_aurora/utils/extension/num_ext.dart';
import 'package:pili_aurora/utils/extension/theme_ext.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart' hide ListTile;

class WhisperSessionItem extends StatelessWidget {
  const WhisperSessionItem({
    super.key,
    required this.item,
    required this.onSetTop,
    required this.onSetMute,
    required this.onRemove,
    required this.onMarkRead,
    required this.isActive,
  });

  final SessionEntry item;
  final ValueChanged<bool> onSetTop;
  final ValueChanged<bool> onSetMute;
  final ValueChanged<SessionKey> onRemove;
  final Future<LoadingState<void>> Function(SessionKey) onMarkRead;
  final bool Function() isActive;

  Future<void> _markRead(BuildContext context) async {
    final result = await _perform(onMarkRead(item.key));
    if (!context.mounted || !isActive()) return;
    await _showResult(context, result, '已标为已读');
  }

  Future<LoadingState<void>?> _perform(
    Future<LoadingState<void>> action,
  ) async {
    final result = await action;
    return isActive() ? result : null;
  }

  Future<void> _showResult(
    BuildContext context,
    LoadingState<void>? result,
    String success,
  ) async {
    if (!context.mounted || !isActive() || result == null) return;
    if (result.isSuccess) {
      SmartDialog.showToast(success);
    } else {
      await result.toast();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final target = item.target;
    final avatar = item.avatar;

    return ListTile(
      safeArea: true,
      tileColor: item.isPinned
          ? theme.colorScheme.onInverseSurface.withValues(
              alpha: theme.isDark ? 0.4 : 0.8,
            )
          : null,
      onLongPress: () => showDialog(
        context: context,
        builder: (_) => SimpleDialog(
          clipBehavior: .hardEdge,
          contentPadding: const .symmetric(vertical: 12),
          children: [
            DialogOption(
              onPressed: () {
                Get.back();
                onSetTop(item.isPinned);
              },
              child: Text(item.isPinned ? '移除置顶' : '置顶'),
            ),
            if (target is PrivateSessionTarget) ...[
              if (kDebugMode || item.unread.isUnread)
                DialogOption(
                  onPressed: () {
                    Get.back();
                    _markRead(context);
                  },
                  child: const Text('标为已读'),
                ),
              DialogOption(
                onPressed: () {
                  Get.back();
                  onSetMute(item.isMuted);
                },
                child: Text('${item.isMuted ? '关闭' : '开启'}免打扰'),
              ),
              DialogOption(
                onPressed: () {
                  Get.back();
                  showConfirmDialog(
                    context: context,
                    title: const Text('确定删除该对话？'),
                    onConfirm: () => onRemove(item.key),
                  );
                },
                child: const Text('删除'),
              ),
            ],
          ],
        ),
      ),
      onSecondaryTapUp: PlatformUtils.isDesktop
          ? (details) => showMenu(
              context: context,
              position: PageUtils.menuPosition(details.globalPosition),
              items: <PopupMenuEntry<Never>>[
                AppPopupMenuItem(
                  height: 42,
                  onTap: () => onSetTop(item.isPinned),
                  child: Text(item.isPinned ? '移除置顶' : '置顶'),
                ),
                if (target is PrivateSessionTarget) ...[
                  if (kDebugMode || item.unread.isUnread)
                    AppPopupMenuItem(
                      height: 42,
                      onTap: () => _markRead(context),
                      child: const Text('标为已读'),
                    ),
                  AppPopupMenuItem(
                    height: 42,
                    onTap: () => onSetMute(item.isMuted),
                    child: Text('${item.isMuted ? '关闭' : '开启'}免打扰'),
                  ),
                  const PopupMenuDivider(height: 10),
                  AppPopupMenuItem(
                    height: 42,
                    onTap: () => showConfirmDialog(
                      context: context,
                      title: const Text('确定删除该对话？'),
                      onConfirm: () => onRemove(item.key),
                    ),
                    child: Text(
                      '删除',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ],
            )
          : null,
      onTap: () => _openTarget(context),
      leading: Builder(
        builder: (context) => GestureDetector(
          onTap: avatar.mid == null
              ? null
              : () => Get.toNamed('/member?mid=${avatar.mid}'),
          child: PendantAvatar(
            avatar.url,
            size: 42,
            badgeSize: 14,
            pendantImage: avatar.pendantUrl,
            vipStatus: avatar.vipStatus,
            officialType: avatar.officialType,
          ),
        ),
      ),
      title: Row(
        spacing: 5,
        children: [
          Expanded(
            child: Row(
              spacing: 5,
              children: [
                Flexible(
                  child: Text(
                    item.name,
                    maxLines: 1,
                    overflow: .ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      color:
                          avatar.vipStatus != null &&
                              avatar.vipStatus! > 0 &&
                              avatar.vipType == 2
                          ? theme.colorScheme.vipColor
                          : null,
                    ),
                  ),
                ),
                if (item.userLabel?.isNotEmpty == true)
                  PBadge(
                    isStack: false,
                    type: .line_secondary,
                    size: .small,
                    fontSize: 10,
                    isBold: false,
                    text: item.userLabel!,
                  ),
                if (item.isLive)
                  Image.asset(
                    Assets.livingRect,
                    height: 15,
                    cacheHeight: 15.cacheSize(context),
                    filterQuality: .low,
                  ),
              ],
            ),
          ),
          if (item.timestampMicros case final timestamp?)
            Text(
              DateFormatUtils.dateFormat((timestamp ~/ 1000000).toInt()),
              style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
            ),
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              item.summary,
              maxLines: 1,
              overflow: .ellipsis,
              style: theme.textTheme.labelMedium!.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          if (item.isMuted)
            Icon(
              size: 16,
              Icons.notifications_off,
              color: theme.colorScheme.outline,
            )
          else if (item.unread.isUnread)
            Badge(
              label: item.unread.style == SessionUnreadStyle.number
                  ? Text(item.unread.number.toString())
                  : null,
            ),
        ],
      ),
    );
  }

  void _openTarget(BuildContext context) {
    if (!context.mounted || !isActive()) return;
    final target = item.target;
    if (target case PrivateSessionTarget(:final talkerId)) {
      Get.toNamed(
        '/whisperDetail',
        arguments: {
          'talkerId': talkerId,
          'name': item.name,
          'face': item.avatar.url,
          'mid': ?item.avatar.mid,
          'isLive': item.isLive,
        },
      );
      return;
    }
    if (target case FoldSessionTarget(:final folder?)) {
      Get.to(WhisperSecPage(name: item.name, folder: folder));
      return;
    }
    if (target is SystemSessionTarget) {
      if (target.kind == SessionKind.system) {
        Get.toNamed('/sysMsg');
      } else {
        SmartDialog.showToast(target.kind.name);
      }
      return;
    }
    if (target case FoldSessionTarget(:final kind)) {
      SmartDialog.showToast(kind.name);
      return;
    }
    SmartDialog.showToast('该会话暂不支持打开');
  }
}
