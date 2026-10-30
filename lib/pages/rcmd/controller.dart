import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/pages/common/discovery_list_controller.dart';
import 'package:pili_aurora/services/account_service.dart';
import 'package:pili_aurora/services/blocked_authors.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/media_author_filter.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

class _RecommendationQuery {
  _RecommendationQuery(this.context, this.app, this.saved);

  final Object? context;
  final bool app;
  final List<dynamic> saved;
  final items = <dynamic>[];
  final seen = <Object>{};
  final pending = HashSet<Object>.identity();
  CancelToken cancel = CancelToken();
  final requests = <int, Future<LoadingState<List<dynamic>>>>{};
  Future<void>? preparation;
  Future<void>? running;
  TraceOperation? firstItems;
  TraceOperation? firstViewport;
  int? historyStart;
  String? error;
  int nextPage = 0,
      nextRequest = 0,
      batchSize = 10,
      emptyPages = 0,
      moreItems = 0;
  bool stopped = false;
}

class RcmdController extends DiscoveryListController<List<dynamic>, dynamic> {
  late bool enableSaveLastData = Pref.enableSaveLastData;
  bool get appRcmd => Pref.appRcmd;

  int? lastRefreshAt;
  late bool savedRcmdTip = Pref.savedRcmdTip;

  _RecommendationQuery? _query;
  StreamSubscription<bool>? _accountChanges;
  bool _disposed = false, _active = true;
  int _viewportItems = 0, _columns = 1;

  int get viewportItems => _viewportItems;
  String? get loadMoreError => _query?.error;
  bool isPending(Object item) => _query?.pending.contains(item) ?? false;

  bool _current(_RecommendationQuery query) =>
      !_disposed &&
      identical(query, _query) &&
      identical(query.context, queryContext) &&
      query.app == appRcmd;

  int _target(_RecommendationQuery query) =>
      math.max(1, math.max(_viewportItems, query.moreItems));

  @override
  bool get isLoading => _query?.running != null;

  @override
  bool get isEnd => _query?.stopped ?? false;

  @override
  void onInit() {
    super.onInit();
    page = 0;
    // 首次布局提供容量后启动，Web 首包也能按实际窗口大小请求。
    if (Get.isRegistered<AccountService>()) {
      _accountChanges = Get.find<AccountService>().isLogin.listen((_) {
        if (_query case final query? when !_current(query)) {
          _invalidate(query);
          if (_active) {
            unawaited(onRefresh());
          } else {
            _query = null;
            lastRefreshAt = null;
            loadingState.value = LoadingState.loading();
          }
        }
      });
    }
  }

  void updateViewport({
    required int itemCount,
    required int columns,
    required bool active,
  }) {
    if (_disposed) return;
    final changed = _viewportItems != itemCount || _active != active;
    _viewportItems = itemCount;
    _columns = columns;
    _active = active;
    if (!active) return;
    final query = _query;
    if (query == null || !_current(query)) {
      unawaited(onRefresh());
    } else if (changed && !query.stopped) {
      unawaited(_run(query));
    }
  }

  Future<LoadingState<List<dynamic>>> fetchRecommendations({
    required int index,
    required int pageSize,
    required CancelToken cancelToken,
  }) => appRcmd
      ? VideoHttp.rcmdVideoListApp(freshIdx: index, cancelToken: cancelToken)
      : VideoHttp.rcmdVideoList(
          freshIdx: index,
          ps: pageSize,
          cancelToken: cancelToken,
        );

  @override
  List<dynamic> filterCandidates(
    Iterable<dynamic> source, {
    Iterable<dynamic> existing = const [],
  }) {
    final seen = existing
        .map(MediaAuthorFilter.contentKey)
        .whereType<Object>()
        .toSet();
    return super.filterCandidates(source, existing: existing).where((item) {
      final key = MediaAuthorFilter.contentKey(item);
      return key == null || seen.add(key);
    }).toList();
  }

  void _publish(_RecommendationQuery query) {
    if (!_current(query)) return;
    final data = List<dynamic>.of(query.items);
    lastRefreshAt = savedRcmdTip && query.saved.isNotEmpty
        ? query.historyStart
        : null;
    loadingState.value = Success(data);
    final ready = data.where((item) => !isPending(item)).length;
    if (ready > 0) {
      query.firstItems?.finish(details: {'items': ready});
      query.firstItems = null;
    }
    if (_viewportItems > 0 &&
        data.length >= _viewportItems &&
        data.take(_viewportItems).every((item) => !isPending(item))) {
      query.firstViewport?.finish(
        details: {'items': ready, 'target': _viewportItems},
      );
      query.firstViewport = null;
    }
  }

  bool _needsAuthorCheck(dynamic item) =>
      Pref.filterBlockedAuthors &&
      Pref.checkCooperativeAuthors &&
      GlobalData().blackMids.isNotEmpty &&
      MediaAuthorFilter.videos(item).any(
        (video) =>
            video.authors.isCooperation &&
            video.authors.mids == null &&
            !BlockedAuthors.contains(video.ownerMid),
      );

  Future<void> _checkAuthor(
    _RecommendationQuery query,
    Object item,
    void Function() onChecked,
  ) async {
    query.pending.add(item);
    await cooperativeAuthors.prepare(
      MediaAuthorFilter.videos(item).toList(),
      isCurrent: () => _current(query),
    );
    if (!_current(query)) return;
    query.pending.remove(item);
    final blocked = filterCandidates([item]).isEmpty;
    if (blocked) {
      _remove(query, item);
    }
    onChecked();
    _publish(query);
    if (blocked && _active && !query.stopped) unawaited(_run(query));
  }

  void _settleBatch(_RecommendationQuery query, List<dynamic> added) {
    if (!_current(query)) return;
    query.emptyPages = added.any(query.items.contains)
        ? 0
        : query.emptyPages + 1;
    // 连续五页无有效增长后等待用户刷新，避免重复或全屏蔽来源持续请求。
    if (query.emptyPages >= 5) {
      query.stopped = true;
      _invalidate(query);
    }
    if (_active && !query.stopped) unawaited(_run(query));
  }

  void _accept(_RecommendationQuery query, List<dynamic> source) {
    final added = filterCandidates(source).where((item) {
      final key = MediaAuthorFilter.contentKey(item);
      return key == null || query.seen.add(key);
    }).toList();
    query.items.addAll(added);
    if (query.nextPage == 1) {
      final saved = filterCandidates(query.saved, existing: query.items);
      query.saved
        ..clear()
        ..addAll(saved);
      query.historyStart = query.items.length;
      query.items.addAll(saved);
      query.seen.addAll(
        saved.map(MediaAuthorFilter.contentKey).whereType<Object>(),
      );
    }
    final checking = [
      ...added,
      if (query.nextPage == 1) ...query.saved,
    ].where(_needsAuthorCheck).toList();
    var remaining = checking.length;
    void checked() {
      if (--remaining == 0) _settleBatch(query, added);
    }

    for (final item in checking) {
      unawaited(_checkAuthor(query, item as Object, checked));
    }
    _publish(query);
    if (checking.isEmpty) _settleBatch(query, added);
  }

  void _finishTrace(_RecommendationQuery query) {
    query.firstItems?.finish(details: {'interrupted': true});
    query.firstViewport?.finish(details: {'interrupted': true});
    query.firstItems = query.firstViewport = null;
  }

  void _invalidate(_RecommendationQuery query) {
    query.cancel.cancel('recommendations invalidated');
    query.requests.clear();
    _finishTrace(query);
  }

  void _startRequests(_RecommendationQuery query) {
    // App 的 idx/pull 顺序推进；Web 首包后最多下载两页并按索引合并。
    final limit = query.app || query.nextPage == 0 ? 1 : 2;
    while (query.requests.length < limit &&
        (query.nextRequest == 0 ||
            query.items.length + query.requests.length * query.batchSize <
                _target(query))) {
      final index = query.nextRequest++;
      query.requests[index] = () async {
        try {
          return await fetchRecommendations(
            index: index,
            pageSize: math.min(
              50,
              math.max(20, _target(query) - query.items.length),
            ),
            cancelToken: query.cancel,
          );
        } catch (_) {
          return const Error('推荐加载失败，请重试');
        }
      }();
    }
  }

  Future<void> _runLoop(_RecommendationQuery query) async {
    try {
      while (_current(query) &&
          _active &&
          !query.stopped &&
          (query.nextPage == 0 ||
              query.requests.isNotEmpty ||
              query.items.length < _target(query))) {
        _startRequests(query);
        if (query.requests.isEmpty) return;
        // 下载不等待卡片作者检查，响应仍按请求索引提交。
        final result = await query.requests[query.nextPage]!;
        if (!_current(query)) return;
        await query.preparation;
        if (!_current(query) || query.stopped) return;
        query.requests.remove(query.nextPage);
        switch (result) {
          case Success(:final response):
            page = ++query.nextPage;
            if (response.isNotEmpty) query.batchSize = response.length;
            _accept(query, response);
          case Error():
            query
              ..stopped = true
              ..error = result.errMsg ?? '推荐加载失败，请重试';
            if (loadingState.value.dataOrNull?.isNotEmpty != true) {
              loadingState.value = result;
            } else {
              loadingState.refresh();
            }
          case Loading():
            query.stopped = true;
        }
      }
    } catch (_) {
      if (_current(query)) {
        query
          ..stopped = true
          ..error = '推荐加载失败，请重试';
        if (loadingState.value.dataOrNull?.isNotEmpty != true) {
          loadingState.value = const Error('推荐加载失败，请重试');
        } else {
          loadingState.refresh();
        }
      }
    } finally {
      if (!_current(query) || query.stopped) _invalidate(query);
    }
  }

  Future<void> _run(_RecommendationQuery query) {
    if (query.running case final running?) return running;
    final running = _runLoop(query).whenComplete(() => query.running = null);
    query.running = running;
    return running;
  }

  @override
  Future<void> queryData([bool isRefresh = true]) {
    if (_disposed) return Future.value();
    if (!isRefresh) return onLoadMore();
    final previous = _query;
    final sameContext = previous == null || _current(previous);
    final visible = sameContext
        ? loadingState.value.dataOrNull
              ?.where((item) => !isPending(item))
              .toList()
        : null;
    final old = enableSaveLastData && visible != null ? visible : <dynamic>[];
    if (previous != null) _invalidate(previous);
    final query = _RecommendationQuery(
      queryContext,
      appRcmd,
      old.length > 200 ? old.take(50).toList() : old,
    );
    _query = query;
    page = 0;
    lastRefreshAt = null;
    if (!sameContext) {
      loadingState.value = LoadingState.loading();
    } else if (visible != null) {
      // 旧查询的占位卡片随刷新撤下，避免新查询失去其检查状态后提前揭示。
      loadingState.value = Success(visible);
    }
    query
      ..firstItems = Diagnostics.instance.begin('recommendFirstItems', 'ready')
      ..firstViewport = Diagnostics.instance.begin(
        'recommendViewport',
        'ready',
      )
      // 同步与下载同时开始，发布前等待屏蔽准备完成。
      ..preparation = prepareQuery();
    return _run(query);
  }

  @override
  Future<LoadingState<List<dynamic>>> customGetData() => fetchRecommendations(
    index: page,
    pageSize: 20,
    cancelToken: CancelToken(),
  );

  @override
  bool handleError(String? errMsg) {
    return enableSaveLastData;
  }

  @override
  void handleListResponse(List<dynamic> dataList) {
    if (enableSaveLastData && page == 0) {
      if (loadingState.value case Success(:final response)) {
        if (response != null && response.isNotEmpty) {
          if (savedRcmdTip) {
            lastRefreshAt = dataList.length;
          }
          final saved = response.length > 200 ? response.take(50) : response;
          dataList.addAll(filterCandidates(saved, existing: dataList));
        }
      }
    }
  }

  @override
  Future<void> onRefresh() {
    return queryData();
  }

  @override
  Future<void> onLoadMore() {
    final query = _query;
    if (query == null || !_current(query)) return onRefresh();
    if (query.stopped || !_active) return Future.value();
    if (query.running case final running?) return running;
    query.moreItems =
        query.items.length + math.max(_columns * 2, query.batchSize);
    return _run(query);
  }

  Future<void> retryLoadMore() {
    final query = _query;
    if (query == null || !_current(query)) return onRefresh();
    query
      ..stopped = false
      ..error = null
      ..cancel = CancelToken()
      ..nextRequest = query.nextPage;
    loadingState.refresh();
    return _run(query);
  }

  void _remove(_RecommendationQuery query, Object item) {
    final index = query.items.indexOf(item);
    if (index < 0) return;
    query.items.removeAt(index);
    query.saved.remove(item);
    if (query.historyStart case final start? when index < start) {
      query.historyStart = start - 1;
    }
  }

  void removeRecommendation(Object item) {
    final query = _query;
    if (query == null || !_current(query)) return;
    if (query.nextPage == 0) {
      query.saved.remove(item);
      final key = MediaAuthorFilter.contentKey(item);
      if (key != null) query.seen.add(key);
      final visible = List<dynamic>.of(loadingState.value.dataOrNull ?? [])
        ..remove(item);
      loadingState.value = Success(visible);
      return;
    }
    _remove(query, item);
    _publish(query);
    if (_active && !query.stopped) unawaited(_run(query));
  }

  @override
  void onClose() {
    _disposed = true;
    unawaited(_accountChanges?.cancel());
    _accountChanges = null;
    if (_query case final query?) _invalidate(query);
    super.onClose();
  }
}
