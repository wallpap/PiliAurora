import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/member/search_type.dart';
import 'package:pili_aurora/pages/dynamics/widgets/dynamic_panel.dart';
import 'package:pili_aurora/pages/member_search/child/widgets/search_archive_grpc.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:pili_aurora/utils/waterfall.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/pages/common/search/scoped_search.dart';
import 'package:pili_aurora/common/widgets/feed_pagination.dart';
import 'package:material_ui/material_ui.dart';
import 'package:waterfall_flow/waterfall_flow.dart'
    hide SliverWaterfallFlowDelegateWithMaxCrossAxisExtent;

class MemberSearchChildPage extends ConsumerStatefulWidget {
  const MemberSearchChildPage({
    super.key,
    required this.keyword,
    required this.owner,
    this.mid,
    required this.searchType,
  });

  final String keyword;
  final Object owner;
  final int? mid;
  final MemberSearchType searchType;

  @override
  ConsumerState<MemberSearchChildPage> createState() =>
      MemberSearchChildPageState();
}

class MemberSearchChildPageState extends ConsumerState<MemberSearchChildPage>
    with AutomaticKeepAliveClientMixin, DynMixin, GridMixin {
  final _scroll = ScrollController();
  ScopedSearchQuery get query => (
    kind: widget.searchType == MemberSearchType.archive
        ? ScopedSearchKind.archive
        : ScopedSearchKind.dynamic,
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
  void didUpdateWidget(MemberSearchChildPage oldWidget) {
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
                top: widget.searchType == MemberSearchType.archive ? 7 : 0,
                bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
              ),
              sliver: switch (widget.searchType) {
                MemberSearchType.archive => _snapshot(),
                MemberSearchType.dynamic => buildPage(
                  _snapshot(),
                ),
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget get _buildLoading {
    return switch (widget.searchType) {
      MemberSearchType.archive => gridSkeleton,
      MemberSearchType.dynamic => dynSkeleton,
    };
  }

  Widget _buildBody(List response) {
    return response.isNotEmpty
        ? switch (widget.searchType) {
            MemberSearchType.archive => SliverGrid.builder(
              gridDelegate: gridDelegate,
              itemBuilder: (context, index) {
                return SearchArchiveGrpc(item: response[index]);
              },
              itemCount: response.length,
            ),
            MemberSearchType.dynamic =>
              GlobalData().dynamicsWaterfallFlow
                  ? SliverWaterfallFlow(
                      gridDelegate: dynGridDelegate,
                      delegate: SliverChildBuilderDelegate(
                        (_, index) => _itemBuilder(response, index),
                        childCount: response.length,
                      ),
                    )
                  : SliverList.builder(
                      itemBuilder: (context, index) =>
                          _itemBuilder(response, index),
                      itemCount: response.length,
                    ),
          }
        : HttpError(onReload: _reload);
  }

  Widget _itemBuilder(List list, int index) {
    return DynamicPanel(item: list[index]);
  }

  @override
  bool get wantKeepAlive => true;
}
