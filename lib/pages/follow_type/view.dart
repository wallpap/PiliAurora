import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart'
    hide SliverGridDelegateWithMaxCrossAxisExtent;
import 'package:pili_aurora/common/skeleton/msg_feed_top.dart';
import 'package:pili_aurora/common/sliver_single_child_delegate.dart';
import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/common/widgets/feed_pagination.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/pendant_avatar.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/view_sliver_safe_area.dart';
import 'package:pili_aurora/models/remote/follow/list.dart';
import 'package:pili_aurora/http/loading_state.dart' as loading;
import 'package:pili_aurora/pages/follow/widgets/follow_item.dart';
import 'package:pili_aurora/pages/follow_type/controller.dart';
import 'package:pili_aurora/pages/follow_type/widgets/item.dart';
import 'package:pili_aurora/pages/share/view.dart' show UserModel;
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/date_utils.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/parse_int.dart';

class FollowTypePage extends ConsumerStatefulWidget {
  const FollowTypePage({
    super.key,
    required this.query,
    this.name,
    this.showName = true,
    this.onSelect,
  });

  factory FollowTypePage.fromArguments(FollowKind kind, Object? arguments) {
    final args = arguments as Map?;
    return FollowTypePage(
      query: (
        kind: kind,
        mid: safeToInt(args?['mid']),
        newFans: kind == FollowKind.fans && args?['newFans'] == true,
      ),
      name: args?['name'] as String?,
    );
  }

  static void open({
    required FollowKind kind,
    required Object? mid,
    String? name,
  }) {
    final target = safeToInt(mid);
    if (target == null) return;
    final route = switch (kind) {
      FollowKind.fans => '/fan',
      FollowKind.same => '/sameFollowing',
      FollowKind.followed => '/followed',
    };
    Get.toNamed(route, arguments: {'mid': target, 'name': name});
  }

  final FollowQuery query;
  final String? name;
  final bool showName;
  final ValueChanged<UserModel>? onSelect;
  @override
  ConsumerState<FollowTypePage> createState() => _FollowTypePageState();
}

class _FollowTypePageState extends ConsumerState<FollowTypePage> {
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    if (ref.read(followQueryProvider(widget.query)).value?.busyMid != null) {
      return;
    }
    await AsyncValue.guard(
      () => ref.refresh(followQueryProvider(widget.query).future),
    );
  }

  Future<void> _remove(FollowItemModel item) async {
    final before = ref.read(followQueryProvider(widget.query)).value;
    final confirmed = await showConfirmDialog(
      context: context,
      title: Text('确定移除 ${item.uname} ？'),
    );
    if (!mounted ||
        !confirmed ||
        !identical(before, ref.read(followQueryProvider(widget.query)).value)) {
      return;
    }
    final result = await ref
        .read(followQueryProvider(widget.query).notifier)
        .remove(item.mid);
    if (!mounted) return;
    if (result.isSuccess) {
      SmartDialog.showToast('移除成功');
    } else {
      result.toast();
    }
  }

  Future<void> _followBack(FollowItemModel item) async {
    final following = item.attribute == 2 || item.attribute == 6;
    final result = await ref
        .read(followQueryProvider(widget.query).notifier)
        .followBack(item.mid);
    if (!mounted) return;
    if (result.isSuccess) {
      SmartDialog.showToast(following ? '取消关注成功' : '回关成功');
    } else {
      result.toast();
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = widget.query;
    final provider = followQueryProvider(query);
    final snapshot = ref.watch(provider);
    final account = ref.watch(mainAccountProvider);
    final owner = (query.mid ?? account.mid) == account.mid;
    final allowEdit =
        query.kind == FollowKind.fans &&
        widget.onSelect == null &&
        owner &&
        account.isLogin;
    String? name = widget.name;
    if (name == null &&
        widget.showName &&
        !(query.kind == FollowKind.fans && owner)) {
      final nameState = ref.watch(followNameProvider(query.mid));
      if (!nameState.isLoading && !nameState.hasError) name = nameState.value;
    }
    final total = snapshot.isLoading || snapshot.hasError
        ? 0
        : snapshot.value?.total ?? 0;
    final title = switch (query.kind) {
      FollowKind.fans =>
        query.newFans
            ? '新增粉丝'
            : owner
            ? '我的粉丝'
            : name == null
            ? ''
            : '$name的粉丝',
      FollowKind.same => '${name == null ? '' : '我与$name的'}共同关注',
      FollowKind.followed => '我关注的$total人也关注了${name ?? 'TA'}',
    };
    return SimpleScaffold(
      appBar: widget.showName || query.newFans
          ? AppBar(title: Text(title))
          : null,
      body: FeedPagination(
        controller: _scroll,
        dataRevision: snapshot,
        dataSource: snapshot.isLoading || snapshot.hasError
            ? null
            : snapshot.value?.source,
        canLoadMore: () {
          final latest = ref.read(provider);
          return !latest.isLoading &&
              !latest.hasError &&
              (latest.value?.canLoadMore ?? false);
        },
        onLoadMore: ref.read(provider.notifier).loadMore,
        child: refreshIndicator(
          onRefresh: _reload,
          child: CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              ViewSliverSafeArea(
                sliver: snapshot.when(
                  skipLoadingOnRefresh: false,
                  skipLoadingOnReload: false,
                  loading: () => query.newFans
                      ? const SliverPrototypeExtentList(
                          prototypeItem: MsgFeedTopSkeleton(),
                          delegate: SliverSingleChildDelegate(
                            count: 12,
                            child: MsgFeedTopSkeleton(),
                          ),
                        )
                      : SliverGrid(
                          gridDelegate: _grid,
                          delegate: const SliverSingleChildDelegate(
                            count: 16,
                            child: MsgFeedTopSkeleton(),
                          ),
                        ),
                  error: (error, _) => HttpError(
                    errMsg: error is loading.Error ? error.errMsg : '加载失败，请重试',
                    onReload: _reload,
                  ),
                  data: (data) => _body(data, allowEdit),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  late final _grid = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: Grid.smallCardWidth * 2,
    mainAxisExtent: 66,
  );
  Widget _body(FollowQueryState data, bool allowEdit) {
    final query = widget.query;
    if (data.items.isEmpty) {
      return query.newFans
          ? const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('暂无粉丝')),
            )
          : HttpError(onReload: _reload);
    }
    Widget itemBuilder(BuildContext context, int index) {
      final item = data.items[index];
      if (query.newFans) {
        final following = item.attribute == 2 || item.attribute == 6;
        return _NewFanItem(
          item: item,
          isFollowing: following,
          isBusy: data.busyMid == item.mid,
          isDisabled: data.busyMid != null || data.isLoadingMore,
          onTap: () => Get.toNamed('/member?mid=${item.mid}'),
          onFollowBack: allowEdit && (item.attribute == 0 || following)
              ? () => _followBack(item)
              : null,
        );
      }
      if (query.kind != FollowKind.fans) return FollowItem(item: item);
      return FollowTypeItem(
        item: item,
        onTap: () {
          if (widget.onSelect case final select?) {
            select(
              UserModel(
                mid: item.mid,
                name: item.uname ?? '',
                avatar: item.face ?? '',
                selected: true,
              ),
            );
          } else {
            Get.toNamed('/member?mid=${item.mid}');
          }
        },
        onLongPress: allowEdit && data.busyMid == null && !data.isLoadingMore
            ? () => _remove(item)
            : null,
        onSecondaryTap:
            allowEdit &&
                data.busyMid == null &&
                !data.isLoadingMore &&
                !PlatformUtils.isMobile
            ? () => _remove(item)
            : null,
      );
    }

    return SliverMainAxisGroup(
      slivers: [
        if (query.newFans)
          SliverList.builder(
            itemCount: data.items.length,
            itemBuilder: itemBuilder,
          )
        else
          SliverGrid.builder(
            gridDelegate: _grid,
            itemCount: data.items.length,
            itemBuilder: itemBuilder,
          ),
        if (data.isLoadingMore)
          const SliverToBoxAdapter(child: LinearProgressIndicator()),
        if (data.pageError != null)
          SliverToBoxAdapter(
            child: Center(
              child: TextButton(
                onPressed: () => ref
                    .read(followQueryProvider(query).notifier)
                    .loadMore(retry: true),
                child: Text(data.pageError!),
              ),
            ),
          ),
      ],
    );
  }
}

class _NewFanItem extends StatelessWidget {
  const _NewFanItem({
    required this.item,
    required this.isFollowing,
    required this.isBusy,
    required this.isDisabled,
    required this.onTap,
    required this.onFollowBack,
  });
  final FollowItemModel item;
  final bool isFollowing;
  final bool isBusy;
  final bool isDisabled;
  final VoidCallback onTap;
  final VoidCallback? onFollowBack;
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final time = DateFormatUtils.dateFormat(item.mtime);
    return SizedBox(
      height: 76,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              PendantAvatar(
                size: 46,
                badgeSize: 14,
                item.face,
                officialType: item.officialVerify?.type,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.uname ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                    Text(
                      time.isEmpty ? '关注了我' : '关注了我 · $time',
                      style: TextStyle(
                        color: colorScheme.outline,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (onFollowBack != null)
                FilledButton.tonal(
                  onPressed: isDisabled ? null : onFollowBack,
                  style: FilledButton.styleFrom(
                    visualDensity: .compact,
                    tapTargetSize: .shrinkWrap,
                    padding: const .symmetric(horizontal: 16),
                  ),
                  child: Text(
                    isBusy
                        ? '处理中'
                        : isFollowing
                        ? '取消关注'
                        : '回关',
                  ),
                )
              else if (isFollowing)
                Text(
                  item.attribute == 6 ? '已互关' : '已关注',
                  style: TextStyle(color: colorScheme.outline, fontSize: 12),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
