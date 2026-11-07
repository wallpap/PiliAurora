import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/common/skeleton/media_bangumi.dart';
import 'package:pili_aurora/common/sliver_single_child_delegate.dart';
import 'package:pili_aurora/models/search/result.dart';
import 'package:pili_aurora/pages/search_panel/filter_controller.dart';
import 'package:pili_aurora/pages/search_panel/pgc/widgets/item.dart';
import 'package:pili_aurora/pages/search_panel/view.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:material_ui/material_ui.dart'
    hide SliverGridDelegateWithMaxCrossAxisExtent;

class SearchPgcPanel extends CommonSearchPanel {
  const SearchPgcPanel({
    super.key,
    required super.keyword,
    required super.tag,
    required super.searchType,
    super.toTop,
    super.onCount,
  });

  @override
  ConsumerState<SearchPgcPanel> createState() => _SearchPgcPanelState();
}

class _SearchPgcPanelState
    extends
        CommonSearchPanelState<
          SearchPgcPanel,
          SearchPgcData,
          SearchPgcItemModel
        > {
  @override
  late final SearchPanelController<SearchPgcData, SearchPgcItemModel>
  controller = SearchPanelController<SearchPgcData, SearchPgcItemModel>(
    keyword: widget.keyword,
    searchType: widget.searchType,
    tag: widget.tag,
  );

  late final gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: Grid.smallCardWidth * 2,
    mainAxisExtent: 158,
  );

  @override
  Widget buildList(List<SearchPgcItemModel> list) {
    return SliverGrid.builder(
      gridDelegate: gridDelegate,
      itemBuilder: (BuildContext context, int index) {
        return SearchPgcItem(item: list[index]);
      },
      itemCount: list.length,
    );
  }

  @override
  Widget get buildLoading => SliverGrid(
    gridDelegate: gridDelegate,
    delegate: const SliverSingleChildDelegate(
      count: 10,
      child: MediaPgcSkeleton(),
    ),
  );
}
