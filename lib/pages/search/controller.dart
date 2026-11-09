import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/models/search/suggest.dart';
import 'package:pili_aurora/models/remote/search/search_rcmd/data.dart';
import 'package:pili_aurora/models/remote/search/search_trending/data.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

final searchHistoryProvider = NotifierProvider<SearchHistory, List<String>>(
  SearchHistory.new,
);

class SearchHistory extends Notifier<List<String>> {
  @override
  List<String> build() => List.unmodifiable(
    List<String>.from(
      GStorage.historyWord.get('cacheList') ?? const <String>[],
    ),
  );
  void replace(List<String> words) {
    state = List.unmodifiable(words);
    GStorage.historyWord.put('cacheList', state);
  }

  void add(String word) =>
      replace([word, ...state.where((item) => item != word)]);
  void remove(String word) =>
      replace(state.where((item) => item != word).toList());
  void clear() {
    state = const [];
    GStorage.historyWord.delete('cacheList');
  }
}

final recordSearchHistoryProvider = NotifierProvider<RecordSearchHistory, bool>(
  RecordSearchHistory.new,
);

class RecordSearchHistory extends Notifier<bool> {
  @override
  bool build() {
    final subscription = GStorage.setting
        .watch(key: SettingBoxKey.recordSearchHistory)
        .listen((_) => state = Pref.recordSearchHistory);
    ref.onDispose(subscription.cancel);
    return Pref.recordSearchHistory;
  }

  void set(bool value) {
    state = value;
    GStorage.setting.put(SettingBoxKey.recordSearchHistory, value);
  }
}

class SearchState {
  const SearchState({
    this.suggestions = const [],
    required this.trending,
    required this.recommend,
  });
  final List<SearchSuggestItem> suggestions;
  final LoadingState<SearchTrendingData> trending;
  final LoadingState<SearchRcmdData> recommend;
  SearchState copyWith({
    List<SearchSuggestItem>? suggestions,
    LoadingState<SearchTrendingData>? trending,
    LoadingState<SearchRcmdData>? recommend,
  }) => SearchState(
    suggestions: suggestions ?? this.suggestions,
    trending: trending ?? this.trending,
    recommend: recommend ?? this.recommend,
  );
}

final searchProvider =
    NotifierProvider.family<SearchNotifier, SearchState, Object>(
      SearchNotifier.new,
      isAutoDispose: true,
    );

class SearchNotifier extends Notifier<SearchState> {
  SearchNotifier(this.key);
  final Object key;
  Timer? _timer;
  int _suggestVersion = 0, _trendingVersion = 0, _recommendVersion = 0;
  bool _alive = true;
  @override
  SearchState build() {
    ref.watch(recommendAccountProvider);
    _alive = true;
    ref.onDispose(() {
      _alive = false;
      ++_suggestVersion;
      ++_trendingVersion;
      ++_recommendVersion;
      _timer?.cancel();
    });
    if (Pref.enableTrending) unawaited(refreshTrending());
    if (Pref.enableSearchRcmd) unawaited(refreshRecommend());
    return SearchState(
      trending: LoadingState.loading(),
      recommend: LoadingState.loading(),
    );
  }

  void input(String text, {bool immediate = false}) {
    final version = ++_suggestVersion;
    _timer?.cancel();
    if (!Pref.searchSuggestion || text.isEmpty) {
      state = state.copyWith(suggestions: const []);
      return;
    }
    if (immediate) {
      unawaited(_suggest(text, version));
    } else {
      _timer = Timer(
        const Duration(milliseconds: 200),
        () => _suggest(text, version),
      );
    }
  }

  void clearSuggestions() {
    ++_suggestVersion;
    _timer?.cancel();
    state = state.copyWith(suggestions: const []);
  }

  Future<void> _suggest(String text, int version) async {
    final account = Accounts.get(AccountType.recommend);
    try {
      final result = await SearchHttp.searchSuggest(
        term: text,
        account: account,
      );
      if (!_alive ||
          version != _suggestVersion ||
          !identical(account, Accounts.get(AccountType.recommend))) {
        return;
      }
      if (result case Success(:final response)) {
        state = state.copyWith(
          suggestions: List.unmodifiable(response.tag ?? const []),
        );
      }
    } catch (_) {
      // 联想失败时保留现有内容，不影响搜索提交。
    }
  }

  Future<void> refreshTrending() async {
    final version = ++_trendingVersion;
    final account = Accounts.get(AccountType.recommend);
    LoadingState<SearchTrendingData> result;
    try {
      result = await SearchHttp.searchTrending(limit: 10);
    } catch (error, stackTrace) {
      result = Error.fromException(error, stackTrace);
    }
    if (_alive &&
        version == _trendingVersion &&
        identical(account, Accounts.get(AccountType.recommend))) {
      state = state.copyWith(trending: result);
    }
  }

  Future<void> refreshRecommend() async {
    final version = ++_recommendVersion;
    final account = Accounts.get(AccountType.recommend);
    LoadingState<SearchRcmdData> result;
    try {
      result = await SearchHttp.searchRecommend();
    } catch (error, stackTrace) {
      result = Error.fromException(error, stackTrace);
    }
    if (_alive &&
        version == _recommendVersion &&
        identical(account, Accounts.get(AccountType.recommend))) {
      state = state.copyWith(recommend: result);
    }
  }
}
