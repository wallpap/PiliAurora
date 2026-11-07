import 'package:pili_aurora/common/skeleton/msg_feed_top.dart';
import 'package:pili_aurora/common/skeleton/video_card_v.dart';
import 'package:pili_aurora/common/sliver_single_child_delegate.dart';
import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/live/live_search_type.dart';
import 'package:pili_aurora/pages/live_search/widgets/live_search_room.dart';
import 'package:pili_aurora/pages/live_search/widgets/live_search_user.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/pages/common/search/scoped_search.dart';
import 'package:pili_aurora/common/widgets/feed_pagination.dart';
import 'package:material_ui/material_ui.dart'
    hide SliverGridDelegateWithMaxCrossAxisExtent;

class LiveSearchChildPage extends ConsumerStatefulWidget {
  const LiveSearchChildPage({
    super.key,
    required this.keyword,
    required this.owner,
    this.mid,
    required this.searchType,
  });

  final String keyword;
  final Object owner;
  final int? mid;
  final LiveSearchType searchType;

  @override
  ConsumerState<LiveSearchChildPage> createState() =>
      LiveSearchChildPageState();
}

class LiveSearchChildPageState extends ConsumerState<LiveSearchChildPage>
    with AutomaticKeepAliveClientMixin {
  final _scroll = ScrollController();
  ScopedSearchQuery get query => (
    kind: widget.searchType == LiveSearchType.room
        ? ScopedSearchKind.room
        : ScopedSearchKind.user,
    keyword: widget.keyword,
    mid: widget.mid,
    owner: widget.owner,
  );
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(LiveSearchChildPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.owner, widget.owner)) {
      final owner = widget.owner;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(owner, widget.owner) && _scroll.hasClients) {
          _scroll.jumpTo(0);
        }
      });
    }
  }

  void scrollToTop() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _reload() async {
    await AsyncValue.guard(
      () => ref.refresh(scopedSearchProvider(query).future),
    );
  }

  Widget _snapshot() {
    final snapshot = ref.watch(scopedSearchProvider(query));
    return snapshot.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      loading: () => _buildLoading,
      error: (error, _) => HttpError(
        errMsg: error is Error ? error.errMsg : '加载失败，请重试',
        onReload: _reload,
      ),
      data: (data) => SliverMainAxisGroup(
        slivers: [
          _buildBody(data.items),
          if (data.error != null)
            SliverToBoxAdapter(
              child: TextButton(
                onPressed: () => ref
                    .read(scopedSearchProvider(query).notifier)
                    .loadMore(retry: true),
                child: Text(data.error!),
              ),
            ),
          if (data.loadingMore)
            const SliverToBoxAdapter(
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    double padding = widget.searchType == LiveSearchType.room ? 12 : 0;
    final snapshot = ref.watch(scopedSearchProvider(query));
    return FeedPagination(
      controller: _scroll,
      dataRevision: snapshot,
      dataSource: snapshot.value?.source,
      canLoadMore: () {
        final latest = ref.read(scopedSearchProvider(query));
        return !latest.isLoading &&
            !latest.hasError &&
            (latest.value?.canLoadMore ?? false);
      },
      onLoadMore: ref.read(scopedSearchProvider(query).notifier).loadMore,
      child: refreshIndicator(
        onRefresh: _reload,
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.only(
                top: padding,
                left: padding,
                right: padding,
                bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
              ),
              sliver: _snapshot(),
            ),
          ],
        ),
      ),
    );
  }

  Widget get _buildLoading {
    return switch (widget.searchType) {
      LiveSearchType.room => SliverGrid(
        gridDelegate: SliverGridDelegateWithExtentAndRatio(
          mainAxisSpacing: Style.cardSpace,
          crossAxisSpacing: Style.cardSpace,
          maxCrossAxisExtent: Grid.smallCardWidth,
          childAspectRatio: Style.aspectRatio,
          mainAxisExtent: MediaQuery.textScalerOf(context).scale(72),
        ),
        delegate: const SliverSingleChildDelegate(
          count: 10,
          child: VideoCardVSkeleton(),
        ),
      ),
      LiveSearchType.user => SliverGrid(
        gridDelegate: userDelegate,
        delegate: const SliverSingleChildDelegate(
          count: 12,
          child: MsgFeedTopSkeleton(),
        ),
      ),
    };
  }

  late final roomDelegate = SliverGridDelegateWithExtentAndRatio(
    mainAxisSpacing: Style.cardSpace,
    crossAxisSpacing: Style.cardSpace,
    maxCrossAxisExtent: Grid.smallCardWidth,
    childAspectRatio: Style.aspectRatio,
    mainAxisExtent: MediaQuery.textScalerOf(context).scale(60),
  );

  late final userDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: Grid.smallCardWidth * 2,
    mainAxisExtent: 60,
  );

  Widget _buildBody(List response) {
    return response.isNotEmpty
        ? Builder(
            builder: (context) {
              return switch (widget.searchType) {
                LiveSearchType.room => SliverGrid.builder(
                  gridDelegate: roomDelegate,
                  itemBuilder: (context, index) {
                    return LiveCardVSearch(
                      item: response[index],
                    );
                  },
                  itemCount: response.length,
                ),
                LiveSearchType.user => SliverGrid.builder(
                  gridDelegate: userDelegate,
                  itemBuilder: (context, index) {
                    return LiveSearchUserItem(
                      item: response[index],
                    );
                  },
                  itemCount: response.length,
                ),
              };
            },
          )
        : HttpError(onReload: _reload);
  }

  @override
  bool get wantKeepAlive => true;
}
