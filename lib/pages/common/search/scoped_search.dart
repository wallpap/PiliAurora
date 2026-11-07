import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fixnum/fixnum.dart';
import 'package:pili_aurora/grpc/space.dart';
import 'package:pili_aurora/http/live.dart';
import 'package:pili_aurora/http/member.dart';
import 'package:pili_aurora/models/common/live/live_search_type.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/models/common/account_type.dart';

enum ScopedSearchKind { room, user, archive, dynamic }

typedef ScopedSearchQuery = ({
  ScopedSearchKind kind,
  String keyword,
  int? mid,
  Object owner,
});
final scopedSearchProvider =
    AsyncNotifierProvider.family<
      ScopedSearchNotifier,
      ScopedSearchState,
      ScopedSearchQuery
    >(ScopedSearchNotifier.new, isAutoDispose: true, retry: (_, _) => null);

class ScopedSearchState {
  ScopedSearchState({
    required Iterable<dynamic> items,
    required this.nextPage,
    required this.hasMore,
    this.total,
    this.offset,
    Object? source,
    this.loadingMore = false,
    this.error,
    this.emptyPages = 0,
  }) : items = List.unmodifiable(items),
       source = source ?? Object();
  final int emptyPages;
  final List<dynamic> items;
  final int nextPage;
  final bool hasMore;
  final int? total;
  final String? offset;
  final Object source;
  final bool loadingMore;
  final String? error;
  bool get canLoadMore => hasMore && !loadingMore && error == null;
  ScopedSearchState operation({bool loadingMore = false, String? error}) =>
      ScopedSearchState(
        items: items,
        nextPage: nextPage,
        hasMore: hasMore,
        total: total,
        offset: offset,
        source: source,
        loadingMore: loadingMore,
        error: error,
        emptyPages: emptyPages,
      );
}

class ScopedSearchNotifier extends AsyncNotifier<ScopedSearchState> {
  ScopedSearchNotifier(this.query);
  final ScopedSearchQuery query;
  bool get live =>
      query.kind == ScopedSearchKind.room ||
      query.kind == ScopedSearchKind.user;
  @override
  Future<ScopedSearchState> build() {
    final account = ref.watch(
      live ? recommendAccountProvider : mainAccountProvider,
    );
    return _page(account, null);
  }

  Future<ScopedSearchState> _page(
    Account account,
    ScopedSearchState? before,
  ) async {
    final page = before?.nextPage ?? 1;
    if (query.keyword.trim().isEmpty) {
      return ScopedSearchState(items: [], nextPage: 1, hasMore: false);
    }
    List<dynamic> rows;
    int? total;
    String? offset;
    bool more;
    if (live) {
      final result = await LiveHttp.liveSearch(
        account: account,
        page: page,
        keyword: query.keyword,
        type: query.kind == ScopedSearchKind.room
            ? LiveSearchType.room
            : LiveSearchType.user,
      );
      final data = result.data;
      rows = query.kind == ScopedSearchKind.room
          ? data.room?.list ?? []
          : data.user?.list ?? [];
      total = query.kind == ScopedSearchKind.room
          ? data.room?.totalRoom
          : data.user?.totalUser;
      more =
          rows.isNotEmpty &&
          (total == null ? rows.length >= 30 : page * 30 < total);
    } else if (query.kind == ScopedSearchKind.archive) {
      final result = await SpaceGrpc.searchArchive(
        account: account,
        keyword: query.keyword,
        mid: Int64(query.mid!),
        pn: page,
        ps: Int64(20),
      );
      rows = result.data.archives;
      total = result.data.total.toInt();
      more = rows.isNotEmpty && page * 20 < total;
    } else {
      final result = await MemberHttp.dynSearch(
        account: account,
        pn: page,
        mid: query.mid!,
        offset: before?.offset ?? '',
        keyword: query.keyword,
      );
      final data = result.data;
      rows = data.items ?? [];
      total = data.total;
      offset = data.offset;
      // 过滤后的空页仍可沿新游标继续；重复游标停止，避免无限补页。
      more =
          data.hasMore == true &&
          offset != null &&
          offset.isNotEmpty &&
          offset != before?.offset;
    }
    Object identity(dynamic row) => switch (query.kind) {
      ScopedSearchKind.room => row.roomid ?? row,
      ScopedSearchKind.user => row.roomid ?? row,
      ScopedSearchKind.archive => row.archive.aid,
      ScopedSearchKind.dynamic => row.idStr ?? row,
    };
    final seen = <Object?>{};
    final items = [
      for (final row in [...?before?.items, ...rows])
        if (seen.add(identity(row))) row,
    ];
    if (before != null &&
        items.length == before.items.length &&
        query.kind != ScopedSearchKind.dynamic) {
      more = false;
    }
    final emptyPages = items.length == (before?.items.length ?? 0)
        ? (before?.emptyPages ?? 0) + 1
        : 0;
    return ScopedSearchState(
      emptyPages: emptyPages,
      items: items,
      total: total ?? before?.total,
      nextPage: page + 1,
      offset: offset,
      hasMore: more && emptyPages < 5,
      source: before?.source,
    );
  }

  Future<void> loadMore({bool retry = false}) async {
    final before = state.value;
    if (state.isLoading ||
        state.hasError ||
        before == null ||
        !before.hasMore ||
        before.loadingMore ||
        (!retry && before.error != null)) {
      return;
    }
    final owner = ref;
    final account = owner.read(
      live ? recommendAccountProvider : mainAccountProvider,
    );
    bool current() => identical(
      account,
      live ? Accounts.get(AccountType.recommend) : Accounts.main,
    );
    if (!current()) return;
    state = AsyncData(before.operation(loadingMore: true));
    try {
      final result = await _page(account, before);
      if (owner.mounted && current()) state = AsyncData(result);
    } catch (_) {
      if (owner.mounted && current()) {
        state = AsyncData(before.operation(error: '加载失败，点击重试'));
      }
    }
  }
}
