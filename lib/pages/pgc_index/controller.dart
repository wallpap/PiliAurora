import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/pgc.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_index_condition/data.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_index_result/list.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

typedef PgcIndexQuery = ({int? indexType, String filters, Object owner});
final pgcConditionsProvider = FutureProvider.autoDispose
    .family<PgcIndexConditionData, int?>((ref, indexType) async {
      final account = ref.watch(mainAccountProvider);
      return (await PgcHttp.pgcIndexCondition(
        account: account,
        seasonType: indexType == null ? 1 : null,
        type: 0,
        indexType: indexType,
      )).data;
    }, retry: (_, _) => null);
final pgcResultsProvider = AsyncNotifierProvider.autoDispose
    .family<PgcResultsNotifier, PgcResultsState, PgcIndexQuery>(
      PgcResultsNotifier.new,
      retry: (_, _) => null,
    );

class PgcResultsState {
  PgcResultsState({
    required Iterable<PgcIndexItem> items,
    required this.nextPage,
    required this.hasMore,
    this.loadingMore = false,
    this.error,
    Object? source,
  }) : items = List.unmodifiable(items),
       source = source ?? Object();
  final List<PgcIndexItem> items;
  final int nextPage;
  final bool hasMore;
  final bool loadingMore;
  final String? error;
  final Object source;
  bool get canLoadMore => hasMore && !loadingMore && error == null;
  PgcResultsState operation({bool loadingMore = false, String? error}) =>
      PgcResultsState(
        items: items,
        nextPage: nextPage,
        hasMore: hasMore,
        loadingMore: loadingMore,
        error: error,
        source: source,
      );
}

class PgcResultsNotifier extends AsyncNotifier<PgcResultsState> {
  PgcResultsNotifier(this.query);
  final PgcIndexQuery query;
  @override
  Future<PgcResultsState> build() =>
      _page(ref.watch(mainAccountProvider), null);
  Future<PgcResultsState> _page(
    Account account,
    PgcResultsState? before,
  ) async {
    final page = before?.nextPage ?? 1;
    final data = (await PgcHttp.pgcIndexResult(
      account: account,
      page: page,
      params: Map<String, dynamic>.from(jsonDecode(query.filters) as Map),
      seasonType: query.indexType == null ? 1 : null,
      type: 0,
      indexType: query.indexType,
    )).data;
    final seen = <Object>{};
    final rows = data.list ?? <PgcIndexItem>[];
    final items = [
      for (final item in [...?before?.items, ...rows])
        if (seen.add(item.seasonId ?? item)) item,
    ];
    return PgcResultsState(
      items: items,
      nextPage: page + 1,
      hasMore:
          data.hasNext == 1 &&
          rows.isNotEmpty &&
          (before == null || items.length > before.items.length),
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
    final account = owner.read(recommendAccountProvider);
    if (!identical(account, Accounts.get(AccountType.recommend))) return;
    state = AsyncData(before.operation(loadingMore: true));
    try {
      final result = await _page(account, before);
      if (owner.mounted &&
          identical(account, Accounts.get(AccountType.recommend))) {
        state = AsyncData(result);
      }
    } catch (_) {
      if (owner.mounted &&
          identical(account, Accounts.get(AccountType.recommend))) {
        state = AsyncData(before.operation(error: '加载失败，点击重试'));
      }
    }
  }
}
