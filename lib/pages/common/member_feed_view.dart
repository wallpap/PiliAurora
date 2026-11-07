import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/feed_pagination.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/common/member_feed.dart';

mixin MemberFeedView<W extends ConsumerStatefulWidget, T> on ConsumerState<W> {
  MemberFeedKind get feedKind;
  Object get feedMid;
  final Object _feedOwner = Object();
  MemberFeedQuery get feedQuery =>
      (kind: feedKind, mid: feedMid.toString(), owner: _feedOwner);
  MemberFeedState? get feedData {
    final snapshot = ref.read(memberFeedProvider(feedQuery));
    return !snapshot.isLoading && !snapshot.hasError ? snapshot.value : null;
  }

  Future<void> reloadFeed() async {
    ref.invalidate(memberFeedProvider(feedQuery));
    try {
      await ref.read(memberFeedProvider(feedQuery).future);
    } catch (_) {
      /* 错误由页面展示。 */
    }
  }

  Widget watchFeed(Widget Function(LoadingState<List<T>?> state) builder) {
    final snapshot = ref.watch(memberFeedProvider(feedQuery));
    final LoadingState<List<T>?> loading = snapshot.isLoading
        ? LoadingState<List<T>?>.loading()
        : snapshot.hasError
        ? Error(snapshot.error.toString())
        : Success<List<T>?>(snapshot.requireValue.items.cast<T>());
    return builder(loading);
  }

  Widget paginateFeed(Widget child) => FeedPagination.notifications(
    dataRevision: ref.watch(memberFeedProvider(feedQuery)),
    dataSource: feedData?.source,
    canLoadMore: () => feedData?.canLoadMore == true,
    onLoadMore: () =>
        ref.read(memberFeedProvider(feedQuery).notifier).loadMore(),
    child: child,
  );
  Widget get feedFooter => SliverToBoxAdapter(
    child: switch (feedData?.error) {
      final String error => Center(
        child: TextButton(
          onPressed: () => ref
              .read(memberFeedProvider(feedQuery).notifier)
              .loadMore(retry: true),
          child: Text(error),
        ),
      ),
      _ => const SizedBox.shrink(),
    },
  );
}
