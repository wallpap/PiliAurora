import 'package:pili_aurora/common/skeleton/video_card_v.dart';
import 'package:pili_aurora/common/sliver_single_child_delegate.dart';
import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/common/widgets/feed_pagination.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/http/loading_state.dart' show Error;
import 'package:pili_aurora/pages/live_follow/controller.dart';
import 'package:pili_aurora/pages/live_follow/widgets/live_item_follow.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

class LiveFollowPage extends ConsumerStatefulWidget {
  const LiveFollowPage({super.key});

  @override
  ConsumerState<LiveFollowPage> createState() => _LiveFollowPageState();
}

class _LiveFollowPageState extends ConsumerState<LiveFollowPage> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    await AsyncValue.guard(() => ref.refresh(liveFollowProvider.future));
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    final snapshot = ref.watch(liveFollowProvider);
    final count = snapshot.isLoading || snapshot.hasError
        ? null
        : snapshot.value?.liveCount;
    return SimpleScaffold(
      appBar: AppBar(
        title: Text(count != null ? '$count人正在直播' : '关注直播'),
      ),
      body: FeedPagination(
        controller: _scrollController,
        dataRevision: snapshot,
        dataSource: snapshot.value?.source,
        canLoadMore: () {
          final current = ref.read(liveFollowProvider);
          return !current.isLoading &&
              !current.hasError &&
              (current.value?.canLoadMore ?? false);
        },
        onLoadMore: ref.read(liveFollowProvider.notifier).loadMore,
        child: refreshIndicator(
          onRefresh: _reload,
          child: CustomScrollView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.only(
                  left: Style.safeSpace + padding.left,
                  right: Style.safeSpace + padding.right,
                  bottom: padding.bottom + 100,
                ),
                sliver: snapshot.when(
                  skipLoadingOnRefresh: false,
                  skipLoadingOnReload: false,
                  loading: () => SliverGrid(
                    gridDelegate: gridDelegate,
                    delegate: const SliverSingleChildDelegate(
                      count: 10,
                      child: VideoCardVSkeleton(),
                    ),
                  ),
                  error: (error, _) => HttpError(
                    errMsg: error is Error ? error.toString() : '加载失败，请重试',
                    onReload: _reload,
                  ),
                  data: _buildBody,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  late final gridDelegate = SliverGridDelegateWithExtentAndRatio(
    mainAxisSpacing: Style.cardSpace,
    crossAxisSpacing: Style.cardSpace,
    maxCrossAxisExtent: Grid.smallCardWidth,
    childAspectRatio: Style.aspectRatio,
    mainAxisExtent: MediaQuery.textScalerOf(context).scale(90),
  );

  Widget _buildBody(LiveFollowState snapshot) => SliverMainAxisGroup(
    slivers: [
      if (snapshot.items.isNotEmpty)
        SliverGrid.builder(
          gridDelegate: gridDelegate,
          itemBuilder: (context, index) =>
              LiveCardVFollow(liveItem: snapshot.items[index]),
          itemCount: snapshot.items.length,
        )
      else if (!snapshot.hasMore && snapshot.pageError == null)
        HttpError(onReload: _reload),
      if (snapshot.isLoadingMore ||
          (snapshot.items.isEmpty &&
              snapshot.hasMore &&
              snapshot.pageError == null))
        const SliverToBoxAdapter(child: LinearProgressIndicator()),
      if (snapshot.pageError != null)
        SliverToBoxAdapter(
          child: Center(
            child: TextButton(
              onPressed: () =>
                  ref.read(liveFollowProvider.notifier).loadMore(retry: true),
              child: Text(snapshot.pageError!),
            ),
          ),
        ),
    ],
  );
}
