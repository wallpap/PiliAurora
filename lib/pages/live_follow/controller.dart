import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/live.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/live/live_follow/data.dart';
import 'package:pili_aurora/models/remote/live/live_follow/item.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

final liveFollowProvider =
    AsyncNotifierProvider<LiveFollowNotifier, LiveFollowState>(
      LiveFollowNotifier.new,
      isAutoDispose: true,
      retry: (_, _) => null,
    );

class LiveFollowState {
  LiveFollowState({
    required Iterable<LiveFollowItem> items,
    required this.source,
    required this.nextPage,
    required this.hasMore,
    this.liveCount,
    this.totalPages,
    this.sourceTotal,
    this.emptyPages = 0,
    this.isLoadingMore = false,
    this.pageError,
  }) : items = List.unmodifiable(items);

  final List<LiveFollowItem> items;
  final Object source;
  final int nextPage;
  final bool hasMore;
  final int? liveCount;
  final int? totalPages;
  final int? sourceTotal;
  final int emptyPages;
  final bool isLoadingMore;
  final String? pageError;

  bool get canLoadMore => hasMore && !isLoadingMore && pageError == null;

  LiveFollowState withOperation({
    bool isLoadingMore = false,
    String? pageError,
  }) => LiveFollowState(
    items: items,
    source: source,
    nextPage: nextPage,
    hasMore: hasMore,
    liveCount: liveCount,
    totalPages: totalPages,
    sourceTotal: sourceTotal,
    emptyPages: emptyPages,
    isLoadingMore: isLoadingMore,
    pageError: pageError,
  );
}

class LiveFollowNotifier extends AsyncNotifier<LiveFollowState> {
  @override
  Future<LiveFollowState> build() async {
    final account = ref.watch(mainAccountProvider);
    if (!account.isLogin) throw const Error('账号未登录');
    return _merge(null, await _page(account, 1), 1);
  }

  Future<LiveFollowData> _page(Account account, int page) async {
    final result = await LiveHttp.liveFollow(page, account: account);
    return switch (result) {
      Success(:final response) => response,
      _ => throw result,
    };
  }

  LiveFollowState _merge(
    LiveFollowState? current,
    LiveFollowData response,
    int page,
  ) {
    final seen = <int>{};
    final items = [
      for (final item in [...?current?.items, ...?response.list])
        if (item.roomid == null || seen.add(item.roomid!)) item,
    ];
    final liveCount = response.liveCount ?? current?.liveCount;
    final totalPages = response.totalPage ?? current?.totalPages;
    final sourceTotal = response.count ?? current?.sourceTotal;
    final sourceCount = response.sourceCount ?? response.list?.length ?? 0;
    final pageSize = response.pageSize != null && response.pageSize! > 0
        ? response.pageSize!
        : 9;
    final emptyPages = items.length == (current?.items.length ?? 0)
        ? (current?.emptyPages ?? 0) + 1
        : 0;
    final hasMore = totalPages != null
        ? page < totalPages
        : sourceTotal != null
        ? page * pageSize < sourceTotal
        // 缺失远端分页时，对连续无有效增长的页限界，避免无限请求。
        : sourceCount >= pageSize && emptyPages < 5;
    return LiveFollowState(
      items: items,
      source: current?.source ?? Object(),
      nextPage: page + 1,
      // 优先使用服务端分页，不能把“本页全部离线”当成结束。
      hasMore:
          sourceCount > 0 &&
          hasMore &&
          (liveCount == null || items.length < liveCount),
      liveCount: liveCount,
      totalPages: totalPages,
      sourceTotal: sourceTotal,
      emptyPages: emptyPages,
    );
  }

  Future<void> loadMore({bool retry = false}) async {
    final current = state.value;
    if (state.isLoading ||
        state.hasError ||
        current == null ||
        !current.hasMore ||
        current.isLoadingMore ||
        (!retry && current.pageError != null)) {
      return;
    }
    final requestRef = ref;
    final account = requestRef.read(mainAccountProvider);
    state = AsyncData(current.withOperation(isLoadingMore: true));
    try {
      final response = await _page(account, current.nextPage);
      if (!requestRef.mounted || !identical(account, Accounts.main)) return;
      state = AsyncData(_merge(current, response, current.nextPage));
    } catch (_) {
      if (requestRef.mounted && identical(account, Accounts.main)) {
        state = AsyncData(current.withOperation(pageError: '加载失败，点击重试'));
      }
    }
  }
}
