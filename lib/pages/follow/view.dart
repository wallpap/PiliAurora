import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/app_popup_menu_item.dart';
import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/common/widgets/dialog/simple_dialog_option.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart' show tabBarView;
import 'package:pili_aurora/common/widgets/view_safe_area.dart';
import 'package:pili_aurora/pages/common/fab_mixin.dart';
import 'package:pili_aurora/pages/follow/child/child_view.dart';
import 'package:pili_aurora/pages/follow/controller.dart';
import 'package:pili_aurora/pages/follow/widgets/tag_dialog.dart';
import 'package:pili_aurora/pages/follow_tag_sort/view.dart';
import 'package:pili_aurora/pages/follow_type/controller.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/parse_int.dart';
import 'package:pili_aurora/utils/platform_utils.dart';

class FollowPage extends ConsumerStatefulWidget {
  const FollowPage({super.key, this.mid, this.name});
  final int? mid;
  final String? name;
  factory FollowPage.fromArguments(Object? arguments) {
    final args = arguments as Map?;
    return FollowPage(
      mid: safeToInt(args?['mid']),
      name: args?['name'] as String?,
    );
  }
  static void toFollowPage({dynamic mid, String? name}) {
    if (mid == null) return;
    Get.toNamed('/follow', arguments: {'mid': safeToInt(mid), 'name': name});
  }

  @override
  ConsumerState<FollowPage> createState() => _FollowPageState();
}

class _FollowPageState extends ConsumerState<FollowPage>
    with SingleTickerProviderStateMixin, BaseFabMixin, LazyFabMixin {
  Future<void> _create() async {
    final before = ref.read(followTagsProvider);
    if (before.isLoading ||
        before.hasError ||
        before.value == null ||
        before.value!.isSaving) {
      return;
    }
    final name = await showFollowTagNameDialog(context);
    if (!mounted || name == null) return;
    final result = await ref
        .read(followTagsProvider.notifier)
        .create(name, before.requireValue.source);
    if (mounted) {
      if (result.isSuccess) {
        SmartDialog.showToast('创建成功');
      } else {
        result.toast();
      }
    }
  }

  Future<void> _edit(FollowTag tag) async {
    final source = ref.read(followTagsProvider).value?.source;
    if (source == null) return;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        clipBehavior: Clip.hardEdge,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          DialogOption(
            onPressed: () => Navigator.pop(context, 'rename'),
            child: const Text('修改名称', style: TextStyle(fontSize: 14)),
          ),
          DialogOption(
            onPressed: () => Navigator.pop(context, 'remove'),
            child: const Text('删除分组', style: TextStyle(fontSize: 14)),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'rename') {
      final name = await showFollowTagNameDialog(context, name: tag.name);
      if (!mounted || name == null) return;
      final result = await ref
          .read(followTagsProvider.notifier)
          .rename(tag.id, name, source);
      if (mounted) {
        if (result.isSuccess) {
          SmartDialog.showToast('修改成功');
        } else {
          result.toast();
        }
      }
    } else if (action == 'remove') {
      final confirmed = await showConfirmDialog(
        context: context,
        title: const Text('删除分组'),
        content: const Text('删除后，该分组下的用户依旧保留。'),
      );
      if (!mounted || !confirmed) return;
      final result = await ref
          .read(followTagsProvider.notifier)
          .remove(tag.id, source);
      if (mounted) {
        if (result.isSuccess) {
          SmartDialog.showToast('删除成功');
        } else {
          result.toast();
        }
      }
    }
  }

  @override
  bool onNotification(UserScrollNotification notification) =>
      notification.metrics.axisDirection == AxisDirection.down
      ? super.onNotification(notification)
      : false;
  @override
  Widget build(BuildContext context) {
    final account = ref.watch(mainAccountProvider);
    final owner = (widget.mid ?? account.mid) == account.mid;
    final groups = owner ? ref.watch(followTagsProvider) : null;
    final order = owner ? ref.watch(followOrderProvider) : null;
    String? name = widget.name;
    if (!owner && name == null) {
      final state = ref.watch(followNameProvider(widget.mid));
      if (!state.isLoading && !state.hasError) name = state.value;
    }
    final padding = MediaQuery.viewPaddingOf(context);
    final canEdit =
        account.isLogin &&
        groups != null &&
        !groups.isLoading &&
        !groups.hasError &&
        groups.value?.isSaving == false;
    final mid = widget.mid;
    return SimpleScaffold(
      appBar: AppBar(
        title: owner
            ? const Text('我的关注')
            : name == null
            ? const SizedBox.shrink()
            : Text('$name的关注'),
        actions: owner
            ? [
                IconButton(
                  onPressed: canEdit ? _create : null,
                  icon: const Icon(Icons.add),
                  tooltip: '新建分组',
                ),
                IconButton(
                  onPressed: canEdit
                      ? () => Get.to(
                          () => FollowTagSortPage(initial: groups.requireValue),
                        )
                      : null,
                  icon: const Icon(Icons.sort),
                  tooltip: '分组排序',
                ),
                IconButton(
                  onPressed: () =>
                      Get.toNamed('/followSearch', arguments: {'mid': mid}),
                  icon: const Icon(Icons.search_outlined),
                  tooltip: '搜索',
                ),
                PopupMenuButton(
                  itemBuilder: (_) => [
                    AppPopupMenuItem(
                      onTap: () => Get.toNamed('/blackListPage'),
                      child: const Row(
                        spacing: 10,
                        mainAxisSize: MainAxisSize.min,
                        children: [Icon(Icons.block, size: 19), Text('黑名单管理')],
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 6),
              ]
            : null,
      ),
      body: owner
          ? fabAnimWrapper(
              child: groups!.when(
                skipLoadingOnRefresh: false,
                skipLoadingOnReload: false,
                loading: () => m3eLoading,
                error: (_, _) => Column(
                  children: [
                    TextButton(
                      onPressed: () => ref.invalidate(followTagsProvider),
                      child: const Text('分组加载失败，点击重试'),
                    ),
                    Expanded(
                      child: FollowChildPage(
                        key: ObjectKey(account),
                        mid: mid,
                        allowEdit: true,
                      ),
                    ),
                  ],
                ),
                data: (data) => _FollowTabs(
                  key: ObjectKey(account),
                  mid: mid,
                  groups: data,
                  onEdit: canEdit ? _edit : null,
                ),
              ),
            )
          : FollowChildPage(
              key: ObjectKey(account),
              mid: mid,
              name: name,
              showCommon: true,
            ),
      fab: owner
          ? SlideTransition(
              position: fabAnimation,
              child: Padding(
                padding: EdgeInsets.only(
                  right: kFloatingActionButtonMargin + padding.right,
                  bottom: kFloatingActionButtonMargin + padding.bottom,
                ),
                child: FloatingActionButton.extended(
                  onPressed: ref.read(followOrderProvider.notifier).toggle,
                  icon: const Icon(Icons.format_list_bulleted, size: 20),
                  label: Text(order!.title),
                ),
              ),
            )
          : null,
    );
  }
}

class _FollowTabs extends ConsumerStatefulWidget {
  const _FollowTabs({
    super.key,
    required this.mid,
    required this.groups,
    required this.onEdit,
  });
  final int? mid;
  final FollowTagsState groups;
  final ValueChanged<FollowTag>? onEdit;
  @override
  ConsumerState<_FollowTabs> createState() => _FollowTabsState();
}

class _FollowTabsState extends ConsumerState<_FollowTabs>
    with TickerProviderStateMixin {
  late TabController _tabs;
  final _keys = <int?, GlobalKey<FollowChildPageState>>{};
  List<int?> get _ids => [null, ...widget.groups.tags.map((tag) => tag.id)];
  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _ids.length, vsync: this);
  }

  @override
  void didUpdateWidget(_FollowTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldIds = <int?>[null, ...oldWidget.groups.tags.map((tag) => tag.id)];
    if (!listEquals(oldIds, _ids)) {
      final selected = oldIds[_tabs.index];
      _tabs.dispose();
      final index = _ids.indexOf(selected);
      _tabs = TabController(
        length: _ids.length,
        initialIndex: index < 0 ? 0 : index,
        vsync: this,
      );
      _keys.removeWhere((id, _) => !_ids.contains(id));
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(
      followingProvider((mid: widget.mid, tagid: null, keyword: null)),
    );
    final total = all.isLoading || all.hasError ? null : all.value?.total;
    final tags = widget.groups.tags;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ViewSafeArea(
          child: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            controller: _tabs,
            tabs: [
              Tab(text: '全部关注${total == null ? '' : '($total)'}'),
              for (final tag in tags)
                GestureDetector(
                  onLongPress: tag.isCustom && widget.onEdit != null
                      ? () {
                          Feedback.forLongPress(context);
                          widget.onEdit!(tag);
                        }
                      : null,
                  onSecondaryTap:
                      !PlatformUtils.isMobile &&
                          tag.isCustom &&
                          widget.onEdit != null
                      ? () => widget.onEdit!(tag)
                      : null,
                  child: Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${tag.name}${tag.count == null ? '' : '(${tag.count})'} ',
                        ),
                        if (tag.isCustom) const Icon(Icons.menu, size: 18),
                      ],
                    ),
                  ),
                ),
            ],
            onTap: (index) {
              if (!_tabs.indexIsChanging) {
                _keys[_ids[index]]?.currentState?.scrollToTop();
              }
            },
          ),
        ),
        Expanded(
          child: tabBarView(
            controller: _tabs,
            children: [
              for (final id in _ids)
                FollowChildPage(
                  key: _keys.putIfAbsent(
                    id,
                    GlobalKey<FollowChildPageState>.new,
                  ),
                  mid: widget.mid,
                  tagid: id,
                  allowEdit: true,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
