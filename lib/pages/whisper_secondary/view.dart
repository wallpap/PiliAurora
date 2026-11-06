import 'dart:async';

import 'package:pili_aurora/common/widgets/app_popup_menu_item.dart';
import 'package:pili_aurora/common/skeleton/whisper_item.dart';
import 'package:pili_aurora/common/sliver_single_child_delegate.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/common/common_whisper_controller.dart';
import 'package:pili_aurora/pages/whisper/widgets/item.dart';
import 'package:pili_aurora/pages/whisper_secondary/controller.dart';
import 'package:pili_aurora/services/messaging/session_models.dart';
import 'package:pili_aurora/services/messaging/session_providers.dart';
import 'package:pili_aurora/utils/extension/three_dot_ext.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

class WhisperSecPage extends ConsumerWidget {
  const WhisperSecPage({
    super.key,
    required this.name,
    required this.folder,
  });

  final String name;
  final SessionFolder folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionsProvider);
    final controller = WhisperSecController(sessions: sessions, folder: folder);
    return SimpleScaffold(
      appBar: AppBar(
        title: Text(name),
        actions: [_SecondaryActions(controller: controller)],
      ),
      body: refreshIndicator(
        onRefresh: () => _refresh(context, controller),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
              ),
              sliver: _SecondarySessionList(controller: controller),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _refresh(
    BuildContext context,
    WhisperSecController controller,
  ) async {
    if (!context.mounted || !controller.isActive) return;
    await controller.onRefresh();
    if (!context.mounted || !controller.isActive) return;
  }
}

class _SecondaryActions extends ConsumerWidget {
  const _SecondaryActions({required this.controller});

  final WhisperSecController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(sessionListSnapshotProvider(controller.folder));
    if (snapshot.menuItems.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton(
      itemBuilder: (context) => snapshot.menuItems
          .map(
            (item) => AppPopupMenuItem(
              onTap: () => item.action.action(
                context: context,
                controller: controller,
                item: item,
              ),
              child: Row(children: [item.action.icon, Text('  ${item.title}')]),
            ),
          )
          .toList(),
    );
  }
}

class _SecondarySessionList extends ConsumerWidget {
  const _SecondarySessionList({required this.controller});

  final CommonWhisperController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(
      sessionListSnapshotProvider(controller.folder),
    );
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
    CommonWhisperController controller,
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
