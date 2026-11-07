import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/feed_pagination.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/common/search/scoped_search.dart';

/// 直播与空间搜索共用滚动、刷新和分页状态，子页只提供查询与内容布局。
abstract class ScopedSearchPageState<W extends ConsumerStatefulWidget>
    extends ConsumerState<W>
    with AutomaticKeepAliveClientMixin<W> {
  final _scroll = ScrollController();
  ScopedSearchQuery queryFor(W widget);
  ScopedSearchQuery get query => queryFor(widget);
  Widget get buildLoading;
  Widget buildBody(List items);
  EdgeInsets get contentPadding;
  Widget wrapResults(Widget sliver) => sliver;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(W oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(queryFor(oldWidget).owner, query.owner)) {
      final owner = query.owner;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(owner, query.owner) && _scroll.hasClients) {
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

  Future<void> reload() async {
    await AsyncValue.guard(
      () => ref.refresh(scopedSearchProvider(query).future),
    );
  }

  Widget _snapshot(AsyncValue<ScopedSearchState> snapshot) {
    return snapshot.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      loading: () => buildLoading,
      error: (error, _) => HttpError(
        errMsg: error is Error ? error.errMsg : '加载失败，请重试',
        onReload: reload,
      ),
      data: (data) => SliverMainAxisGroup(
        slivers: [
          buildBody(data.items),
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
        onRefresh: reload,
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: contentPadding.add(
                EdgeInsets.only(
                  bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
                ),
              ),
              sliver: wrapResults(_snapshot(snapshot)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
