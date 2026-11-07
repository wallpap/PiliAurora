import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/common/widgets/sliver/sliver_floating_header.dart';
import 'package:pili_aurora/common/widgets/video_card/video_card_h.dart';
import 'package:pili_aurora/models/common/search/video_search_type.dart';
import 'package:pili_aurora/models/search/result.dart';
import 'package:pili_aurora/pages/search/widgets/search_text.dart';
import 'package:pili_aurora/pages/search_panel/video/controller.dart';
import 'package:pili_aurora/pages/search_panel/view.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:material_ui/material_ui.dart';

class SearchVideoPanel extends CommonSearchPanel {
  const SearchVideoPanel({
    super.key,
    required super.keyword,
    required super.tag,
    required super.searchType,
    super.toTop,
    super.onCount,
  });

  @override
  ConsumerState<SearchVideoPanel> createState() => _SearchVideoPanelState();
}

class _SearchVideoPanelState
    extends
        CommonSearchPanelState<
          SearchVideoPanel,
          SearchVideoData,
          SearchVideoItemModel
        >
    with GridMixin, SearchVideoPanelMixin<SearchVideoPanel> {
  @override
  late final SearchVideoController controller = SearchVideoController(
    keyword: widget.keyword,
    searchType: widget.searchType,
    tag: widget.tag,
  );
}

mixin SearchVideoPanelMixin<S extends SearchVideoPanel>
    on
        CommonSearchPanelState<S, SearchVideoData, SearchVideoItemModel>,
        GridMixin {
  @override
  SearchVideoController get controller;

  @override
  Widget buildHeader() {
    return SliverFloatingHeaderWidget(
      backgroundColor: colorScheme.surface,
      child: Padding(
        padding: const .fromLTRB(12, 0, 12, 4),
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Wrap(
                  children: [
                    for (final e in ArchiveFilterType.values)
                      Builder(
                        builder: (_) => SearchText(
                          fontSize: 13,
                          text: e.desc,
                          bgColor: Colors.transparent,
                          textColor: controller.selectedType == e
                              ? colorScheme.primary
                              : colorScheme.outline,
                          onTap: (_) => controller
                            ..order = e == .totalrank ? '' : e.name
                            ..selectedType = e
                            ..onSortSearch(getBack: false),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const VerticalDivider(indent: 7, endIndent: 8),
            const SizedBox(width: 3),
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                tooltip: '筛选',
                style: const ButtonStyle(
                  padding: WidgetStatePropertyAll(EdgeInsets.zero),
                ),
                onPressed: () => controller.onShowFilterDialog(context),
                icon: Icon(
                  Icons.filter_list_outlined,
                  size: 18,
                  color: colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget buildList(List<SearchVideoItemModel> list) {
    return SliverGrid.builder(
      gridDelegate: gridDelegate,
      itemBuilder: (context, index) {
        return VideoCardH(
          videoItem: list[index],
          onRemove: () => removeItem(list[index]),
        );
      },
      itemCount: list.length,
    );
  }

  @override
  Widget get buildLoading => gridSkeleton;
}
