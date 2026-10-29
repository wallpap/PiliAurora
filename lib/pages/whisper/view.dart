import 'dart:async';

import 'package:pili_aurora/common/skeleton/whisper_item.dart';
import 'package:pili_aurora/common/sliver_single_child_delegate.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/msg/msg_unread_type.dart';
import 'package:pili_aurora/pages/whisper/controller.dart';
import 'package:pili_aurora/pages/whisper/widgets/item.dart';
import 'package:pili_aurora/services/messaging/overview.dart';
import 'package:pili_aurora/services/messaging/preferences.dart';
import 'package:pili_aurora/services/messaging/session_models.dart';
import 'package:pili_aurora/services/messaging/session_providers.dart';
import 'package:pili_aurora/utils/extension/three_dot_ext.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class WhisperPage extends ConsumerWidget {
  const WhisperPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final padding = MediaQuery.viewPaddingOf(context);
    final sessions = ref.watch(sessionsProvider);
    final controller = WhisperController(sessions: sessions);
    final overviewHandle = ref.read(overviewHandleProvider);

    return SimpleScaffold(
      appBar: AppBar(
        title: const Text('消息'),
        actions: [
          IconButton(
            tooltip: '新增粉丝',
            onPressed: () => Get.toNamed(
              '/fan',
              arguments: {'newFans': true},
            ),
            icon: const Icon(Icons.account_circle_outlined),
          ),
          _WhisperActions(),
          const SizedBox(width: 5),
        ],
      ),
      body: refreshIndicator(
        onRefresh: () => _refresh(context, controller, overviewHandle),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            _UnreadTopItems(padding: padding),
            SliverPadding(
              padding: EdgeInsets.only(bottom: padding.bottom + 100),
              sliver: _SessionList(controller: controller),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _refresh(
    BuildContext context,
    WhisperController controller,
    UnreadOverview overview,
  ) async {
    if (!context.mounted || !controller.isActive) return;
    await controller.onRefresh();
    if (context.mounted && controller.isActive) {
      await overview.refresh();
    }
  }
}

class _WhisperActions extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(sessionListSnapshotProvider(SessionFolder.home));
    final controller = WhisperController(sessions: ref.watch(sessionsProvider));
    return Row(
      mainAxisSize: .min,
      children: [
        for (final item in snapshot.outsideItems)
          IconButton(
            tooltip: item.title.isNotEmpty ? item.title : null,
            onPressed: () => item.action.action(
              context: context,
              controller: controller,
              item: item,
            ),
            icon: item.action.icon,
          ),
        if (snapshot.menuItems.isNotEmpty)
          PopupMenuButton(
            itemBuilder: (context) => snapshot.menuItems
                .map(
                  (item) => PopupMenuItem(
                    onTap: () => item.action.action(
                      context: context,
                      controller: controller,
                      item: item,
                    ),
                    child: Row(
                      children: [item.action.icon, Text('  ${item.title}')],
                    ),
                  ),
                )
                .toList(),
          ),
      ],
    );
  }
}

class _UnreadTopItems extends ConsumerWidget {
  const _UnreadTopItems({required this.padding});

  final EdgeInsets padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    ref.watch(disableLikeMessagesProvider);
    final controller = WhisperController(sessions: ref.watch(sessionsProvider));
    final overview = ref.watch(overviewProvider);
    const unreadTypes = [
      MsgUnReadType.reply,
      MsgUnReadType.at,
      MsgUnReadType.like,
      MsgUnReadType.sysMsg,
    ];
    return SliverPadding(
      padding: EdgeInsets.only(left: padding.left, right: padding.right),
      sliver: SliverToBoxAdapter(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(controller.msgFeedTopItems.length, (index) {
            final item = controller.msgFeedTopItems[index];
            final count = item.enabled
                ? overview.counts[unreadTypes[index]]
                : 0;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Badge(
                      isLabelVisible: count != null && count > 0,
                      label: count == null ? null : Text(' $count '),
                      alignment: Alignment.topRight,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: .circle,
                          color: theme.colorScheme.onInverseSurface,
                        ),
                        child: Icon(
                          item.icon,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(item.name, style: const TextStyle(fontSize: 13)),
                  ],
                ),
              ),
              onTap: () {
                if (!item.enabled) {
                  SmartDialog.showToast('已禁用');
                  return;
                }
                Get.toNamed(item.route);
              },
            );
          }),
        ),
      ),
    );
  }
}

class _SessionList extends ConsumerWidget {
  const _SessionList({required this.controller});

  final WhisperController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(sessionListSnapshotProvider(SessionFolder.home));
    if (snapshot.isInitialLoading) {
      return const SliverPrototypeExtentList(
        prototypeItem: WhisperItemSkeleton(),
        delegate: SliverSingleChildDelegate(
          count: 12,
          child: WhisperItemSkeleton(),
        ),
      );
    }
    if (snapshot.entries.isEmpty) {
      return HttpError(
        errMsg: snapshot.error,
        onReload: controller.onReload,
      );
    }
    final divider = Divider(
      indent: 72,
      endIndent: 20,
      height: 0,
      color: Colors.grey.withValues(alpha: 0.1),
    );
    return SliverList.separated(
      itemCount: snapshot.entries.length,
      itemBuilder: (context, index) {
        if (index == snapshot.entries.length - 1 && snapshot.hasMore) {
          unawaited(controller.onLoadMore());
        }
        final item = snapshot.entries[index];
        return WhisperSessionItem(
          item: item,
          isActive: () => controller.isActive,
          onSetTop: (isPinned) => unawaited(
            _complete(
              context,
              controller,
              controller.onSetTop(item.key, isPinned: isPinned),
              '置顶设置成功',
            ),
          ),
          onSetMute: (isMuted) => unawaited(
            _complete(
              context,
              controller,
              controller.onSetMute(item.key, isMuted: isMuted),
              '设置成功',
            ),
          ),
          onRemove: (key) => unawaited(
            _complete(context, controller, controller.onRemove(key), '删除成功'),
          ),
          onMarkRead: controller.onMarkRead,
        );
      },
      separatorBuilder: (context, index) => divider,
    );
  }

  Future<void> _complete(
    BuildContext context,
    WhisperController controller,
    Future<LoadingState<void>> operation,
    String success,
  ) async {
    final response = await operation;
    if (!context.mounted || !controller.isActive) return;
    if (response.isSuccess) {
      SmartDialog.showToast(success);
    } else {
      await response.toast();
    }
  }
}
