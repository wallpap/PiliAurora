import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/models/remote/search/search_trending/data.dart';

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
    _alive = true;
    ref.onDispose(() => _alive = false);
    unawaited(refresh());
    return LoadingState.loading();
  }

  Future<void> refresh() async {
    final version = ++_version;
    LoadingState<SearchTrendingData> result;
    try {
      result = await SearchHttp.searchTrending(needsTop: true);
    } catch (_) {
      result = const Error('加载失败，请重试');
    }
    if (_alive && version == _version) state = result;
  }
}
