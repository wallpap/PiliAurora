import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/utils/app_scheme.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

import 'package:pili_aurora/common/widgets/dialog/export_import.dart';
import 'package:pili_aurora/common/widgets/disabled_icon.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/sliver_wrap.dart';
import 'package:pili_aurora/common/widgets/view_insets_safe_area.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/search/search_rcmd/data.dart';
import 'package:pili_aurora/pages/search/controller.dart';
import 'package:pili_aurora/pages/search/widgets/hot_keyword.dart';
import 'package:pili_aurora/pages/search/widgets/search_text.dart';
import 'package:pili_aurora/utils/em.dart' show Em;
import 'package:pili_aurora/utils/extension/size_ext.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _tag = Object();
  final _controller = TextEditingController();
  final _focus = FocusNode();
  late final String? _hintText;
  int _initIndex = 0;
  bool _showUid = false;
  SearchNotifier get _search => ref.read(searchProvider(_tag).notifier);
  SearchState get _state => ref.watch(searchProvider(_tag));
  List<String> get _history => ref.watch(searchHistoryProvider);
  void _input(String value) {
    setState(() => _showUid = IdUtils.digitOnlyRegExp.hasMatch(value));
    _search.input(value);
  }

  void _clear() {
    if (_controller.text.isEmpty) {
      Get.back();
      return;
    }
    _controller.clear();
    _input('');
    _focus.requestFocus();
  }

  Future<void> _submit() async {
    if (_controller.text.isEmpty) {
      if (_hintText == null || _hintText.isEmpty) return;
      _controller.text = _hintText;
      _input(_controller.text);
    }
    final text = _controller.text;
    if (await PiliScheme.routePushFromUrl(text, selfHandle: true)) return;
    if (!mounted) return;
    if (ref.read(recordSearchHistoryProvider)) {
      ref.read(searchHistoryProvider.notifier).add(text);
    }
    _focus.unfocus();
    final result = await Get.toNamed(
      '/searchResult',
      parameters: {'keyword': text},
      arguments: {
        'initIndex': _initIndex,
        'fromSearch': true,
        'onIndexChanged': (int index) {
          _initIndex = index;
        },
      },
    );
    if (!mounted) return;
    _focus.requestFocus();
    if (result == true) _search.input(text, immediate: true);
  }

  void _clickKeyword(String keyword, {bool clearSuggest = true}) {
    _controller.text = keyword;
    setState(() => _showUid = IdUtils.digitOnlyRegExp.hasMatch(keyword));
    if (clearSuggest) {
      _search.clearSuggestions();
    } else {
      _search.input(keyword, immediate: true);
    }
    _submit();
  }

  void _clearHistory() {
    final history = ref.read(searchHistoryProvider.notifier);
    showConfirmDialog(
      context: context,
      title: const Text('确定清空搜索历史？'),
      onConfirm: history.clear,
    );
  }

  late ThemeData theme;
  late bool isPortrait;
  late EdgeInsets padding;

  @override
  void initState() {
    super.initState();
    _hintText = Get.parameters['hintText'];
    _controller.text = Get.parameters['text'] ?? '';
    _showUid = IdUtils.digitOnlyRegExp.hasMatch(_controller.text);
    if (_controller.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search.input(_controller.text, immediate: true);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    theme = Theme.of(context);
    padding = MediaQuery.viewPaddingOf(context);
    isPortrait = MediaQuery.sizeOf(context).isPortrait;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(searchProvider(_tag));
    final trending = Pref.enableTrending ? _buildHotSearch() : null;
    final rcmd = Pref.enableSearchRcmd
        ? _buildHotSearch(isTrending: false)
        : null;

    return SimpleScaffold(
      appBar: _buildAppBar,
      body: Padding(
        padding: .only(left: padding.left, right: padding.right),
        child: ViewInsetsSafeArea(
          child: CustomScrollView(
            slivers: [
              if (Pref.searchSuggestion) _buildSearchSuggest(),
              if (isPortrait) ...[
                ?trending,
                _buildHistory,
                ?rcmd,
              ] else if (trending != null || rcmd != null)
                SliverCrossAxisGroup(
                  slivers: [
                    SliverMainAxisGroup(slivers: [?trending, ?rcmd]),
                    _buildHistory,
                  ],
                )
              else
                _buildHistory,
              SliverPadding(padding: .only(bottom: padding.bottom)),
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget get _buildAppBar => AppBar(
    shape: Border(
      bottom: BorderSide(
        color: theme.dividerColor.withValues(alpha: 0.08),
        width: 1,
      ),
    ),
    actions: [
      _showUid
          ? IconButton(
              tooltip: 'UID搜索用户',
              icon: const Icon(Icons.person_outline, size: 22),
              onPressed: () => Get.toNamed(
                '/member?mid=${_controller.text}',
              ),
            )
          : const SizedBox.shrink(),
      IconButton(
        tooltip: '清空',
        icon: const Icon(Icons.clear, size: 22),
        onPressed: _clear,
      ),
      IconButton(
        tooltip: '搜索',
        onPressed: _submit,
        icon: const Icon(Icons.search, size: 22),
      ),
      const SizedBox(width: 10),
    ],
    title: TextField(
      autofocus: true,
      focusNode: _focus,
      controller: _controller,
      textInputAction: TextInputAction.search,
      onChanged: _input,
      decoration: InputDecoration(
        visualDensity: .standard,
        hintText: _hintText ?? '搜索',
        border: InputBorder.none,
      ),
      onSubmitted: (value) => _submit(),
    ),
  );

  Widget _buildSearchSuggest() {
    final list = _state.suggestions;
    return list.isNotEmpty && list.first.term != null && _controller.text != ''
        ? SliverList.list(
            children: list
                .map(
                  (item) => InkWell(
                    borderRadius: const .all(.circular(4)),
                    onTap: () => _clickKeyword(
                      item.term!,
                      clearSuggest: false,
                    ),
                    child: Padding(
                      padding: const .only(left: 20, top: 9, bottom: 9),
                      child: Text.rich(
                        TextSpan(
                          children: Em.regTitle(item.textRich)
                              .map(
                                (e) => TextSpan(
                                  text: e.text,
                                  style: e.isEm
                                      ? TextStyle(
                                          fontWeight: .bold,
                                          color: theme.colorScheme.primary,
                                        )
                                      : null,
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          )
        : const SliverToBoxAdapter();
  }

  Widget _buildHotSearch({
    bool isTrending = true,
  }) {
    final text = Text(
      isTrending ? '大家都在搜' : '搜索发现',
      strutStyle: const StrutStyle(leading: 0, height: 1),
      style: theme.textTheme.titleMedium!.copyWith(
        height: 1,
        fontWeight: .bold,
      ),
    );
    final outline = theme.colorScheme.outline;
    final secondary = theme.colorScheme.secondary;
    final style = TextStyle(
      height: 1,
      fontSize: 13,
      color: outline,
    );
    return SliverPadding(
      padding: .fromLTRB(
        10,
        !isTrending && (isPortrait || Pref.enableTrending) ? 4 : 25,
        4,
        25,
      ),
      sliver: SliverMainAxisGroup(
        slivers: [
          SliverPadding(
            padding: const .fromLTRB(6, 0, 6, 6),
            sliver: SliverToBoxAdapter(
              child: Row(
                mainAxisAlignment: .spaceBetween,
                children: [
                  isTrending
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            text,
                            const SizedBox(width: 14),
                            TextButton(
                              style: const ButtonStyle(
                                visualDensity: .compact,
                                tapTargetSize: .shrinkWrap,
                                padding: WidgetStatePropertyAll(
                                  .symmetric(horizontal: 10),
                                ),
                              ),
                              onPressed: () => Get.toNamed('/searchTrending'),
                              child: Row(
                                children: [
                                  Text(
                                    '完整榜单',
                                    strutStyle: const StrutStyle(
                                      leading: 0,
                                      height: 1,
                                    ),
                                    style: style,
                                  ),
                                  Icon(
                                    size: 18,
                                    Icons.keyboard_arrow_right,
                                    color: outline,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : text,
                  TextButton.icon(
                    style: const ButtonStyle(
                      visualDensity: .compact,
                      tapTargetSize: .shrinkWrap,
                      padding: WidgetStatePropertyAll(
                        .symmetric(horizontal: 10),
                      ),
                    ),
                    onPressed: isTrending
                        ? _search.refreshTrending
                        : _search.refreshRecommend,
                    icon: Icon(
                      Icons.refresh_outlined,
                      size: 18,
                      color: secondary,
                    ),
                    label: Text(
                      '刷新',
                      strutStyle: const StrutStyle(leading: 0, height: 1),
                      style: TextStyle(height: 1, color: secondary),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _buildHotKey(
            isTrending ? _state.trending : _state.recommend,
            isTrending,
          ),
        ],
      ),
    );
  }

  late final mainAxisExtent = 16 + MediaQuery.textScalerOf(context).scale(14);
  Widget get _buildHistory {
    final list = _history;
    if (list.isEmpty) {
      return const SliverToBoxAdapter();
    }
    final secondary = theme.colorScheme.secondary;
    return SliverPadding(
      padding: .fromLTRB(
        10,
        !isPortrait
            ? 25
            : Pref.enableTrending
            ? 0
            : 6,
        6,
        25,
      ),
      sliver: SliverMainAxisGroup(
        slivers: [
          SliverPadding(
            padding: const .fromLTRB(6, 0, 6, 6),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  Text(
                    '搜索历史',
                    strutStyle: const StrutStyle(leading: 0, height: 1),
                    style: theme.textTheme.titleMedium!.copyWith(
                      height: 1,
                      fontWeight: .bold,
                    ),
                  ),
                  const SizedBox(width: 12),
                  _recordBtn,
                  _exportBtn,
                  const Spacer(),
                  TextButton.icon(
                    style: const ButtonStyle(
                      visualDensity: .compact,
                      tapTargetSize: .shrinkWrap,
                      padding: WidgetStatePropertyAll(
                        .symmetric(horizontal: 10),
                      ),
                    ),
                    onPressed: _clearHistory,
                    icon: Icon(
                      Icons.clear_all_outlined,
                      size: 18,
                      color: secondary,
                    ),
                    label: Text(
                      '清空',
                      style: TextStyle(height: 1, color: secondary),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverFixedWrap(
            mainAxisExtent: mainAxisExtent,
            spacing: 8,
            runSpacing: 8,
            delegate: SliverChildBuilderDelegate(
              addAutomaticKeepAlives: false,
              addRepaintBoundaries: false,
              childCount: list.length,
              (context, index) => SearchText(
                text: list[index],
                onTap: _clickKeyword,
                onLongPress: ref.read(searchHistoryProvider.notifier).remove,
                height: 1,
                maxLines: 1,
                fontSize: 14,
                overflow: .ellipsis,
                padding: const .fromLTRB(11, 8, 11, 0),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget get _recordBtn {
    final enable = ref.watch(recordSearchHistoryProvider);
    return IconButton(
      iconSize: 22,
      tooltip: enable ? '记录搜索' : '无痕搜索',
      icon: DisabledIcon(
        disable: !enable,
        child: Icon(
          Icons.history,
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
        ),
      ),
      style: const ButtonStyle(
        visualDensity: .comfortable,
        tapTargetSize: .shrinkWrap,
        padding: WidgetStatePropertyAll(.zero),
      ),
      onPressed: () {
        ref.read(recordSearchHistoryProvider.notifier).set(!enable);
      },
    );
  }

  Widget get _exportBtn => IconButton(
    iconSize: 22,
    tooltip: '导入/导出历史记录',
    icon: Icon(
      Icons.import_export_outlined,
      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
    ),
    style: const ButtonStyle(
      visualDensity: .comfortable,
      tapTargetSize: .shrinkWrap,
      padding: WidgetStatePropertyAll(.zero),
    ),
    onPressed: () {
      final history = ref.read(searchHistoryProvider.notifier);
      final words = ref.read(searchHistoryProvider);
      showImportExportDialog<List>(
        context,
        title: '历史记录',
        localFileName: () => 'search',
        onExport: () => jsonEncode(words),
        onImport: (json) => history.replace(List<String>.from(json)),
      );
    },
  );

  Widget _buildHotKey(
    LoadingState<SearchRcmdData> loadingState,
    bool isTrending,
  ) {
    return switch (loadingState) {
      Success(:final response) when (response.list?.isNotEmpty ?? false) =>
        SliverHotKeyword(
          hotSearchList: response.list!,
          onClick: _clickKeyword,
        ),
      Error(:final errMsg) => HttpError(
        safeArea: false,
        errMsg: errMsg,
        onReload: isTrending
            ? _search.refreshTrending
            : _search.refreshRecommend,
      ),
      _ => const SliverToBoxAdapter(),
    };
  }
}
