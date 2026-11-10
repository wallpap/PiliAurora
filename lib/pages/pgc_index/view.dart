import 'package:pili_aurora/common/widgets/scroll_physics.dart' show tabBarView;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:pili_aurora/utils/extension/scroll_controller_ext.dart';

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/common/widgets/feed_pagination.dart';
import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/common/widgets/animated_height.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/self_sized_horizontal_list.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_index_condition/data.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_index_condition/sort.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_index_condition/value.dart';
import 'package:pili_aurora/models/remote/pgc/pgc_index_result/list.dart';
import 'package:pili_aurora/pages/pgc_index/controller.dart';
import 'package:pili_aurora/pages/pgc_index/widgets/pgc_card_v_pgc_index.dart';
import 'package:pili_aurora/pages/search/widgets/search_text.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:material_ui/material_ui.dart';

class PgcIndexPage extends ConsumerStatefulWidget {
  const PgcIndexPage({super.key, this.indexType, this.toTop});
  final ValueListenable<int>? toTop;

  final int? indexType;

  @override
  ConsumerState<PgcIndexPage> createState() => _PgcIndexPageState();
}

class _PgcIndexPageState extends ConsumerState<PgcIndexPage>
    with AutomaticKeepAliveClientMixin {
  final _owner = Object();
  final _scroll = ScrollController();
  bool _expanded = false;
  final Map<String, dynamic> _selected = {};
  PgcIndexQuery? _query;
  Map<String, dynamic> _params(PgcIndexConditionData data) => {
    if (data.order?.isNotEmpty == true) 'order': data.order!.first.field,
    for (final filter in data.filter ?? [])
      if (filter.field != null)
        filter.field!: filter.values?.firstOrNull?.keyword,
    ..._selected,
  };
  void _reloadResults() => ref.invalidate(pgcResultsProvider(_query!));
  @override
  void initState() {
    super.initState();
    widget.toTop?.addListener(_scroll.animToTop);
  }

  @override
  void dispose() {
    widget.toTop?.removeListener(_scroll.animToTop);
    _scroll.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => widget.indexType != null;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final conditions = ref.watch(pgcConditionsProvider(widget.indexType));
    final body = conditions.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      loading: () => m3eLoading,
      error: (error, _) => scrollErrorWidget(
        errMsg: error.toString(),
        onReload: () => ref.invalidate(pgcConditionsProvider(widget.indexType)),
      ),
      data: (data) => _buildBody(theme, Success(data)),
    );
    return widget.indexType == null
        ? SimpleScaffold(
            appBar: AppBar(title: const Text('索引')),
            body: body,
          )
        : body;
  }

  Widget _withResults(
    PgcIndexConditionData data,
    Widget Function(AsyncValue<PgcResultsState>) builder,
  ) {
    _query = (
      indexType: widget.indexType,
      filters: jsonEncode(_params(data)),
      owner: _owner,
    );
    final snapshot = ref.watch(pgcResultsProvider(_query!));
    final value = !snapshot.isLoading && !snapshot.hasError
        ? snapshot.value
        : null;
    return FeedPagination(
      controller: _scroll,
      dataRevision: snapshot,
      dataSource: value?.source,
      canLoadMore: () =>
          !snapshot.isLoading &&
          !snapshot.hasError &&
          snapshot.value?.canLoadMore == true,
      onLoadMore: () =>
          ref.read(pgcResultsProvider(_query!).notifier).loadMore(),
      child: builder(snapshot),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    LoadingState<PgcIndexConditionData> loadingState,
  ) {
    final padding = MediaQuery.viewPaddingOf(context);
    return switch (loadingState) {
      Loading() => m3eLoading,
      Success(:final response) => Builder(
        builder: (context) {
          int count =
              (response.order?.isNotEmpty == true ? 1 : 0) +
              (response.filter?.length ?? 0);
          if (count == 0) return const SizedBox.shrink();
          return Padding(
            padding: EdgeInsets.only(left: padding.left, right: padding.right),
            child: _withResults(
              response,
              (results) => CustomScrollView(
                controller: _scroll,
                slivers: [
                  if (widget.indexType != null)
                    const SliverToBoxAdapter(child: SizedBox(height: 12)),
                  SliverToBoxAdapter(
                    child: count > 5
                        ? AnimatedHeightWidget(
                            curve: Curves.easeInOut,
                            expand: _expanded,
                            duration: const Duration(milliseconds: 200),
                            child: _buildSortsWidget(theme, count, response),
                          )
                        : _buildSortsWidget(theme, count, response),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.only(
                      left: Style.safeSpace,
                      right: Style.safeSpace,
                      top: 12,
                      bottom: padding.bottom + 100,
                    ),
                    sliver: results.when(
                      skipLoadingOnRefresh: false,
                      skipLoadingOnReload: false,
                      loading: () => linearLoading,
                      error: (error, _) => HttpError(
                        errMsg: error.toString(),
                        onReload: _reloadResults,
                      ),
                      data: (data) => SliverMainAxisGroup(
                        slivers: [
                          _buildList(Success(data.items)),
                          if (data.error != null)
                            SliverToBoxAdapter(
                              child: Center(
                                child: TextButton(
                                  onPressed: () => ref
                                      .read(
                                        pgcResultsProvider(_query!).notifier,
                                      )
                                      .loadMore(retry: true),
                                  child: Text(data.error!),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
      Error(:final errMsg) => scrollErrorWidget(
        errMsg: errMsg,
        onReload: () => ref.invalidate(pgcConditionsProvider(widget.indexType)),
      ),
    };
  }

  Widget _buildSortWidget(
    ThemeData theme,
    int index,
    PgcIndexConditionData data,
    Object item,
    Map<String, dynamic> indexParams,
  ) {
    final String text;
    final String key;
    final String? value;
    final bool isCurr;

    if (item is PgcConditionOrder) {
      if (item.field == null) return const SizedBox.shrink();
      text = item.name ?? item.field!;
      key = 'order';
      value = item.field;
      isCurr = indexParams[key] == item.field;
    } else if (item is PgcConditionValue) {
      text = item.name ?? item.keyword ?? '其他';
      if (data.order?.isNotEmpty == true) index -= 1;
      final field = data.filter![index].field;
      if (field == null) return const SizedBox.shrink();
      key = field;
      value = item.keyword;
      isCurr = indexParams[key] == item.keyword;
    } else {
      throw UnsupportedError(item.toString());
    }

    return SearchText(
      bgColor: isCurr
          ? theme.colorScheme.secondaryContainer
          : Colors.transparent,
      textColor: isCurr
          ? theme.colorScheme.onSecondaryContainer
          : theme.colorScheme.onSurfaceVariant,
      text: text,
      padding: const .symmetric(horizontal: 6, vertical: 3),
      onTap: (_) => setState(() {
        _selected[key] = value;
        if (_scroll.hasClients) _scroll.jumpTo(0);
      }),
    );
  }

  Widget _buildSortsWidget(
    ThemeData theme,
    int count,
    PgcIndexConditionData data,
  ) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ...List.generate(
        count > 5
            ? _expanded
                  ? count
                  : count ~/ 2
            : count,
        (index) {
          final isFirst = index == 0;
          List? item = data.order?.isNotEmpty == true
              ? isFirst
                    ? data.order
                    : data.filter![index - 1].values
              : data.filter![index].values;
          if (item != null && item.isNotEmpty) {
            return SelfSizedHorizontalList(
              padding: isFirst
                  ? const .symmetric(horizontal: 12)
                  : const .fromLTRB(12, 10, 12, 0),
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, childIndex) => _buildSortWidget(
                theme,
                index,
                data,
                item[childIndex],
                _params(data),
              ),
              itemCount: item.length,
            );
          }
          return const SizedBox.shrink();
        },
      ),
      if (count > 5) ...[
        const SizedBox(height: 8),
        GestureDetector(
          behavior: .opaque,
          onTap: () => setState(() => _expanded = !_expanded),
          child: Center(
            child: Row(
              mainAxisSize: .min,
              children: [
                Text(
                  _expanded ? '收起' : '展开',
                  style: TextStyle(color: theme.colorScheme.outline),
                ),
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  color: theme.colorScheme.outline,
                ),
              ],
            ),
          ),
        ),
      ],
    ],
  );

  late final gridDelegate = SliverGridDelegateWithExtentAndRatio(
    mainAxisSpacing: Style.cardSpace,
    crossAxisSpacing: Style.cardSpace,
    maxCrossAxisExtent: Grid.smallCardWidth * 0.6,
    childAspectRatio: 0.75,
    mainAxisExtent: MediaQuery.textScalerOf(context).scale(50),
  );

  Widget _buildList(LoadingState<List<PgcIndexItem>?> loadingState) {
    return switch (loadingState) {
      Loading() => linearLoading,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemBuilder: (context, index) {
                  return PgcCardVPgcIndex(item: response[index]);
                },
                itemCount: response.length,
              )
            : HttpError(onReload: _reloadResults),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: _reloadResults,
      ),
    };
  }
}

class PgcIndexTabs extends StatefulWidget {
  const PgcIndexTabs({super.key});
  @override
  State<PgcIndexTabs> createState() => _PgcIndexTabsState();
}

class _PgcIndexTabsState extends State<PgcIndexTabs>
    with SingleTickerProviderStateMixin {
  static const _titles = ['全部', '电影', '电视剧', '纪录片', '综艺'];
  static const _types = [102, 2, 5, 3, 7];
  late final _tabs = TabController(length: _types.length, vsync: this);
  final _signals = List.generate(_types.length, (_) => ValueNotifier(0));
  @override
  void dispose() {
    _tabs.dispose();
    for (final signal in _signals) {
      signal.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SimpleScaffold(
    appBar: AppBar(title: const Text('索引')),
    body: SafeArea(
      top: false,
      bottom: false,
      child: Column(
        children: [
          TabBar(
            controller: _tabs,
            tabs: [for (final title in _titles) Tab(text: title)],
            onTap: (index) {
              if (!_tabs.indexIsChanging) _signals[index].value++;
            },
          ),
          Expanded(
            child: tabBarView(
              controller: _tabs,
              children: [
                for (var i = 0; i < _types.length; i++)
                  PgcIndexPage(indexType: _types[i], toTop: _signals[i]),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
