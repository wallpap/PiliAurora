import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/common/search/search_type.dart';
import 'package:pili_aurora/models/search/result.dart';
import 'package:pili_aurora/models/search/search_esports.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/services/blocked_authors.dart';
import 'package:pili_aurora/services/cooperative_authors.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/media_author_filter.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

typedef SearchResultsQuery = ({
  String keyword,
  SearchType type,
  Object owner,
  String filters,
  Object revision,
});
final searchResultsProvider = AsyncNotifierProvider.autoDispose
    .family<SearchResultsNotifier, SearchResultsState, SearchResultsQuery>(
      SearchResultsNotifier.new,
      retry: (_, _) => null,
    );

class SearchResultsState {
  SearchResultsState({
    required Iterable<dynamic> items,
    required this.nextPage,
    required this.hasMore,
    this.total,
    this.loadingMore = false,
    this.error,
    this.emptyPages = 0,
    this.firstAid,
    Iterable<SearchUser> users = const [],
    Iterable<SearchPgcItemModel> media = const [],
    Iterable<SearchActivity> activities = const [],
    this.esports,
    Object? source,
  }) : items = List.unmodifiable(items),
       users = List.unmodifiable(users),
       media = List.unmodifiable(media),
       activities = List.unmodifiable(activities),
       source = source ?? Object();
  final List<dynamic> items;
  final List<SearchUser> users;
  final List<SearchPgcItemModel> media;
  final List<SearchActivity> activities;
  final SearchEsports? esports;
  final int? firstAid;
  final int nextPage;
  final int? total;
  final bool hasMore;
  final int emptyPages;
  final bool loadingMore;
  final Object? error;
  final Object source;
  bool get canLoadMore => hasMore && !loadingMore && error == null;
  SearchResultsState operation({
    bool loadingMore = false,
    Object? error,
    Iterable<dynamic>? items,
  }) => SearchResultsState(
    items: items ?? this.items,
    nextPage: nextPage,
    hasMore: hasMore,
    total: total,
    users: users,
    media: media,
    activities: activities,
    esports: esports,
    firstAid: firstAid,
    source: source,
    loadingMore: loadingMore,
    error: error,
    emptyPages: emptyPages,
  );
}

class SearchResultsNotifier extends AsyncNotifier<SearchResultsState> {
  SearchResultsNotifier(this.query);
  final SearchResultsQuery query;
  String? _token;
  Set<Object> _hidden = {};
  @override
  Future<SearchResultsState> build() {
    final account = ref.watch(recommendAccountProvider);
    final main = ref.watch(mainAccountProvider);
    _token = null;
    _hidden = {};
    return _page(ref, account, main, null);
  }

  bool _current(Ref owner, Account account, Account main) =>
      owner.mounted &&
      identical(account, Accounts.get(AccountType.recommend)) &&
      identical(main, Accounts.main);
  Object _identity(dynamic item) => item is SearchPgcItemModel
      ? ('pgc', item.seasonId ?? item.mediaId ?? item)
      : MediaAuthorFilter.contentKey(item) ?? item as Object;
  Future<SearchResultsState> _page(
    Ref owner,
    Account account,
    Account main,
    SearchResultsState? before,
  ) async {
    final hidden = _hidden;
    final filters = Map<String, dynamic>.from(jsonDecode(query.filters) as Map);
    final filtering = Pref.filterBlockedAuthors;
    await BlockedAuthors.ensureLoaded();
    if (!_current(owner, account, main)) throw const Error('查询已更新');
    var page = before?.nextPage ?? 1;
    var emptyPages = before?.emptyPages ?? 0;
    var more = false;
    var total = before?.total;
    var firstAid = before?.firstAid;
    var users = before?.users ?? <SearchUser>[];
    var media = before?.media ?? <SearchPgcItemModel>[];
    var activities = before?.activities ?? <SearchActivity>[];
    var esports = before?.esports;
    final items = <dynamic>[...?before?.items];
    final seen = <Object>{
      for (final item in items) _identity(item),
    };
    final startLength = items.length;
    for (var attempt = 0; attempt < 5; attempt++) {
      final type =
          query.type == SearchType.all &&
              (page > 1 || filters['filtered'] == true)
          ? SearchType.video
          : query.type;
      final result = await SearchHttp.searchByType<SearchNumData>(
        account: account,
        searchType: type,
        keyword: query.keyword,
        page: page,
        order: filters['order'],
        duration: filters['duration'],
        tids: filters['tids'],
        orderSort: filters['orderSort'],
        userType: filters['userType'],
        categoryId: filters['categoryId'],
        pubBegin: filters['pubBegin'],
        pubEnd: filters['pubEnd'],
        gaiaVtoken: _token,
      );
      if (!_current(owner, account, main)) throw const Error('查询已更新');
      final data = result.data;
      final rows = data.list ?? <dynamic>[];
      if (page == 1) {
        total = data.numResults;
        if (data is SearchVideoData) {
          firstAid = data.list?.firstOrNull?.aid;
          users = (data.searchUser ?? [])
              .where((e) => !filtering || !BlockedAuthors.contains(e.mid))
              .toList();
          media = data.searchMedia ?? [];
          activities = data.searchActivity ?? [];
          esports = data.searchEsports;
        }
      }
      if (filtering && Pref.checkCooperativeAuthors) {
        final videos = MediaAuthorFilter.videos(rows)
            .where(
              (e) =>
                  e.authors.isCooperation &&
                  e.authors.mids == null &&
                  !BlockedAuthors.contains(e.ownerMid),
            )
            .toList();
        if (videos.isNotEmpty) {
          await CooperativeAuthors.shared.prepare(
            videos,
            isCurrent: () => _current(owner, account, main),
          );
        }
      }
      if (!_current(owner, account, main)) throw const Error('查询已更新');
      final oldLength = items.length;
      for (final item in rows) {
        if (filtering &&
            MediaAuthorFilter.isBlocked(
              item,
              BlockedAuthors.contains,
              includeCoauthors: Pref.checkCooperativeAuthors,
            )) {
          continue;
        }
        final key = _identity(item);
        if (!hidden.contains(key) && seen.add(key)) items.add(item);
      }
      emptyPages = items.length == oldLength ? emptyPages + 1 : 0;
      more =
          rows.isNotEmpty &&
          (total == null ? rows.length >= 20 : page * 20 < total) &&
          emptyPages < 5;
      if (!filtering && items.length == oldLength) more = false;
      page++;
      if (!more || !filtering || items.length - startLength >= 20) break;
    }
    return SearchResultsState(
      items: items.where((item) => !hidden.contains(_identity(item))),
      total: total,
      nextPage: page,
      hasMore: more,
      firstAid: firstAid,
      users: users,
      media: media,
      activities: activities,
      esports: esports,
      source: before?.source,
      emptyPages: emptyPages,
    );
  }

  Future<void> _verified(
    Ref owner,
    Account account,
    Account main,
    SearchResultsState? before,
  ) async {
    state = before == null
        ? const AsyncLoading()
        : AsyncData(before.operation(loadingMore: true));
    try {
      final result = await _page(owner, account, main, before);
      if (_current(owner, account, main)) state = AsyncData(result);
    } catch (error, stack) {
      if (_current(owner, account, main)) {
        state = before == null
            ? AsyncError(error, stack)
            : AsyncData(state.requireValue.operation(error: error));
      }
    }
  }

  Future<void> verify(
    SearchVerificationRequired challenge,
    String token,
  ) async {
    final before = !state.isLoading && !state.hasError ? state.value : null;
    if (state.isLoading ||
        !identical(state.error ?? before?.error, challenge)) {
      return;
    }
    final owner = ref;
    final account = owner.read(recommendAccountProvider);
    final main = owner.read(mainAccountProvider);
    if (!_current(owner, account, main)) return;
    _token = token;
    await _verified(owner, account, main, before);
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
    final account = owner.read(recommendAccountProvider);
    final main = owner.read(mainAccountProvider);
    if (!_current(owner, account, main)) return;
    await _verified(owner, account, main, before);
  }

  void remove(Object item) {
    if (!_current(
      ref,
      ref.read(recommendAccountProvider),
      ref.read(mainAccountProvider),
    )) {
      return;
    }
    final data = state.value;
    if (state.isLoading || state.hasError || data == null) return;
    _hidden.add(_identity(item));
    state = AsyncData(
      data.operation(
        items: data.items.where((e) => !identical(e, item)),
        loadingMore: data.loadingMore,
        error: data.error,
      ),
    );
  }
}
