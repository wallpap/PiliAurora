import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/skeleton/msg_feed_top.dart';
import 'package:pili_aurora/common/sliver_single_child_delegate.dart';
import 'package:pili_aurora/common/widgets/button/more_btn.dart';
import 'package:pili_aurora/common/widgets/feed_pagination.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/http/loading_state.dart' show Error;
import 'package:pili_aurora/models/remote/follow/list.dart';
import 'package:pili_aurora/pages/follow/controller.dart';
import 'package:pili_aurora/pages/follow/widgets/follow_item.dart';
import 'package:pili_aurora/pages/follow_type/controller.dart';
import 'package:pili_aurora/pages/follow_type/view.dart';
import 'package:pili_aurora/pages/share/view.dart' show UserModel;
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts.dart';

class FollowChildPage extends ConsumerStatefulWidget {
  const FollowChildPage({
    super.key,
    this.mid,
    this.tagid,
    this.keyword,
    this.onSelect,
    this.name,
    this.showCommon = false,
    this.allowEdit = false,
  });
  final int? mid;
  final int? tagid;
  final String? keyword;
  final ValueChanged<UserModel>? onSelect;
  final String? name;
  final bool showCommon;
  final bool allowEdit;
  FollowingQuery get query => (mid: mid, tagid: tagid, keyword: keyword);
  @override
  ConsumerState<FollowChildPage> createState() => FollowChildPageState();
}

class FollowChildPageState extends ConsumerState<FollowChildPage>
    with AutomaticKeepAliveClientMixin {
  final _scroll = ScrollController();
  void scrollToTop() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    await AsyncValue.guard(
      () => ref.refresh(followingProvider(widget.query).future),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final provider = followingProvider(widget.query);
    final snapshot = ref.watch(provider);
    final account = ref.watch(mainAccountProvider);
    final same = widget.showCommon
        ? ref.watch(
            followQueryProvider((
              kind: FollowKind.same,
              mid: widget.mid,
              newFans: false,
            )),
          )
        : null;
    final padding = MediaQuery.viewPaddingOf(context);
    final colorScheme = ColorScheme.of(context);
    return Padding(
      padding: EdgeInsets.only(left: padding.left, right: padding.right),
      child: FeedPagination(
        controller: _scroll,
        dataRevision: snapshot,
        dataSource: snapshot.value?.source,
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
              if (same != null && !same.isLoading && !same.hasError)
                _buildSameFollowing(colorScheme, same.requireValue.items),
              SliverPadding(
                padding: EdgeInsets.only(bottom: padding.bottom + 100),
                sliver: snapshot.when(
                  skipLoadingOnRefresh: false,
                  skipLoadingOnReload: false,
                  loading: () => const SliverPrototypeExtentList(
                    prototypeItem: MsgFeedTopSkeleton(),
                    delegate: SliverSingleChildDelegate(
                      count: 12,
                      child: MsgFeedTopSkeleton(),
                    ),
                  ),
                  error: (error, _) => HttpError(
                    errMsg: error is Error ? error.errMsg : '加载失败，请重试',
                    onReload: _reload,
                  ),
                  data: (data) => data.items.isEmpty
                      ? HttpError(onReload: _reload)
                      : SliverList.builder(
                          itemCount: data.items.length + 1,
                          itemBuilder: (_, index) {
                            if (index == data.items.length) {
                              if (data.pageError != null) {
                                return TextButton(
                                  onPressed: () => ref
                                      .read(provider.notifier)
                                      .loadMore(retry: true),
                                  child: Text(data.pageError!),
                                );
                              }
                              if (data.isLoadingMore) {
                                return const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                );
                              }
                              return const SizedBox.shrink();
                            }
                            return FollowItem(
                              item: data.items[index],
                              account: account,
                              isOwner:
                                  widget.allowEdit &&
                                  widget.onSelect == null &&
                                  account.isLogin &&
                                  (widget.mid ?? account.mid) == account.mid,
                              onSelect: widget.onSelect == null
                                  ? null
                                  : (user) {
                                      final latest = ref.read(provider);
                                      if (identical(account, Accounts.main) &&
                                          !latest.isLoading &&
                                          !latest.hasError &&
                                          identical(
                                            data.source,
                                            latest.value?.source,
                                          )) {
                                        widget.onSelect!(user);
                                      }
                                    },
                              afterMod: (_) {
                                if (!mounted ||
                                    !identical(account, Accounts.main)) {
                                  return;
                                }
                                ref.invalidate(followingProvider);
                                if (ref
                                        .read(followTagsProvider)
                                        .value
                                        ?.isSaving !=
                                    true) {
                                  ref.invalidate(followTagsProvider);
                                }
                              },
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSameFollowing(
    ColorScheme colorScheme,
    List<FollowItemModel> response,
  ) {
    return response.isNotEmpty
        ? SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: 16,
                    right: 16,
                    bottom: 6,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '我们的共同关注',
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      moreTextButton(
                        onTap: () => FollowTypePage.open(
                          kind: FollowKind.same,
                          mid: widget.mid ?? ref.read(mainAccountProvider).mid,
                          name: widget.name,
                        ),
                        color: colorScheme.outline,
                      ),
                    ],
                  ),
                ),
              ),
              SliverList.builder(
                itemCount: min(3, response.length),
                itemBuilder: (_, index) => FollowItem(item: response[index]),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: 16,
                    top: 16,
                    bottom: 6,
                  ),
                  child: Text(
                    '全部关注',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          )
        : const SliverToBoxAdapter();
  }

  @override
  bool get wantKeepAlive => true;
}
