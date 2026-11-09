import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/remote/search/search_trending/data.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts.dart';

final searchTrendingProvider =
    NotifierProvider<SearchTrendingNotifier, LoadingState<SearchTrendingData>>(
      SearchTrendingNotifier.new,
      isAutoDispose: true,
    );

class SearchTrendingNotifier
    extends Notifier<LoadingState<SearchTrendingData>> {
  int _version = 0;
  bool _alive = true;
  @override
  LoadingState<SearchTrendingData> build() {
    ref.watch(recommendAccountProvider);
    _alive = true;
    ref.onDispose(() {
      _alive = false;
      ++_version;
    });
    unawaited(refresh());
    return LoadingState.loading();
  }

  Future<void> refresh() async {
    final version = ++_version;
    final account = Accounts.get(AccountType.recommend);
    LoadingState<SearchTrendingData> result;
    try {
      result = await SearchHttp.searchTrending(needsTop: true);
    } catch (error, stackTrace) {
      result = Error.fromException(error, stackTrace);
    }
    if (_alive &&
        version == _version &&
        identical(account, Accounts.get(AccountType.recommend))) {
      state = result;
    }
  }
}
