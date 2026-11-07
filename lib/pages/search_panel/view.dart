import 'package:pili_aurora/services/account_providers.dart';

import 'dart:async';

import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/utils/request_utils.dart';

import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/common/widgets/feed_pagination.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/search/search_type.dart';
import 'package:pili_aurora/models/search/result.dart';
import 'package:pili_aurora/pages/search_panel/controller.dart';
import 'package:pili_aurora/pages/search_panel/filter_controller.dart';
import 'package:pili_aurora/utils/extension/scroll_controller_ext.dart';
import 'package:material_ui/material_ui.dart';

abstract class CommonSearchPanel extends ConsumerStatefulWidget {
  const CommonSearchPanel({
    super.key,
    required this.keyword,
    required this.searchType,
    required this.tag,
    this.toTop,
    this.onCount,
  });
  final String keyword;
  final SearchType searchType;
  final Object tag;
  final ValueListenable<int>? toTop;
  final ValueChanged<int?>? onCount;
}

abstract class CommonSearchPanelState<
  S extends CommonSearchPanel,
  R extends SearchNumData<T>,
  T
>
    extends ConsumerState<S>
    with AutomaticKeepAliveClientMixin {
  SearchPanelController<R, T> get controller;
  final scrollController = ScrollController();
  Object _revision = Object();
  SearchResultsQuery get query => (
    keyword: widget.keyword,
    type: widget.searchType,
    owner: widget.tag,
    filters: jsonEncode(controller.filters),
    revision: _revision,
  );
  late ColorScheme colorScheme;
  bool _initialized = false;
  Object? _challenge;
  Timer? _verificationTimer;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    colorScheme = ColorScheme.of(context);
    if (!_initialized) {
      _initialized = true;
      controller
        ..reload = _reload
        ..onInit();
      widget.toTop?.addListener(scrollController.animToTop);
    }
  }

  void _reload() {
    if (!mounted || controller.isClosed) return;
    scrollController.jumpToTop();
    setState(() => _revision = Object());
  }

  Future<void> _refresh() async {
    final key = query;
    ref.invalidate(searchResultsProvider(key));
    try {
      await ref.read(searchResultsProvider(key).future);
    } catch (_) {
      /* 页面展示错误。 */
    }
  }

  void removeItem(T item) =>
      ref.read(searchResultsProvider(query).notifier).remove(item as Object);
  @override
  bool get wantKeepAlive => true;
  @override
  void dispose() {
    widget.toTop?.removeListener(scrollController.animToTop);
    _verificationTimer?.cancel();
    scrollController.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final key = query;
    final provider = searchResultsProvider(key);
    final snapshot = ref.watch(provider);
    final data = !snapshot.isLoading && !snapshot.hasError
        ? snapshot.value
        : null;
    controller.results = data;
    // Tab 数量仅投影当前有效快照，延后通知父页面以避免构建期间改状态。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          query != key ||
          !identical(ref.read(provider), snapshot)) {
        return;
      }
      final challenge = snapshot.error ?? data?.error;
      if (challenge is SearchVerificationRequired &&
          !identical(_challenge, challenge)) {
        _challenge = challenge;
        bool currentChallenge() {
          if (!mounted || query != key) return false;
          final latest = ref.read(provider);
          return !latest.isLoading &&
              identical(latest.error ?? latest.value?.error, challenge);
        }

        RequestUtils.validate(
          challenge.voucher,
          (token) {
            if (!currentChallenge()) return;
            _verificationTimer?.cancel();
            _verificationTimer = Timer(const Duration(milliseconds: 200), () {
              if (currentChallenge()) {
                unawaited(ref.read(provider.notifier).verify(challenge, token));
              }
            });
          },
          account: ref.read(recommendAccountProvider),
          isCurrent: currentChallenge,
        ).catchError((Object _) {
          if (currentChallenge()) const Error('验证未完成，请重试').toast();
        });
      }
      widget.onCount?.call(data?.total);
      if (data != null) controller.onResults(data);
    });
    return refreshIndicator(
      onRefresh: _refresh,
      child: FeedPagination(
        controller: scrollController,
        dataRevision: snapshot,
        dataSource: data?.source,
        canLoadMore: () =>
            !snapshot.isLoading &&
            !snapshot.hasError &&
            ref.read(provider).value?.canLoadMore == true,
        onLoadMore: () => ref.read(provider.notifier).loadMore(),
        child: CustomScrollView(
          controller: scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            ?buildHeader(),
            SliverPadding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
              ),
              sliver: snapshot.when(
                skipLoadingOnRefresh: false,
                skipLoadingOnReload: false,
                loading: () => buildLoading,
                error: (error, _) =>
                    HttpError(errMsg: error.toString(), onReload: _reload),
                data: (data) => _buildBody(Success(data.items.cast<T>())),
              ),
            ),
            if (data?.error case final error?)
              SliverToBoxAdapter(
                child: Center(
                  child: TextButton(
                    onPressed: () =>
                        ref.read(provider.notifier).loadMore(retry: true),
                    child: Text(error.toString()),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget get buildLoading;
  Widget _buildBody(LoadingState<List<T>?> state) => switch (state) {
    Loading() => buildLoading,
    Success(:final response) =>
      response != null &&
              (response.isNotEmpty ||
                  controller.results?.users.isNotEmpty == true ||
                  controller.results?.media.isNotEmpty == true ||
                  controller.results?.activities.isNotEmpty == true ||
                  controller.results?.esports != null)
          ? buildList(response)
          : HttpError(onReload: _reload),
    Error(:final errMsg) => HttpError(errMsg: errMsg, onReload: _reload),
  };
  Widget? buildHeader() => null;
  Widget buildList(List<T> list);
}
