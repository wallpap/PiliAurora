import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/models/common/member/search_type.dart';
import 'package:pili_aurora/pages/dynamics/widgets/dynamic_panel.dart';
import 'package:pili_aurora/pages/member_search/child/widgets/search_archive_grpc.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:pili_aurora/utils/waterfall.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/pages/common/search/scoped_search.dart';
import 'package:pili_aurora/pages/common/search/scoped_search_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:waterfall_flow/waterfall_flow.dart'
    hide SliverWaterfallFlowDelegateWithMaxCrossAxisExtent;

class MemberSearchChildPage extends ConsumerStatefulWidget {
  const MemberSearchChildPage({
    super.key,
    required this.keyword,
    required this.owner,
    this.mid,
    required this.searchType,
  });

  final String keyword;
  final Object owner;
  final int? mid;
  final MemberSearchType searchType;

  @override
  ConsumerState<MemberSearchChildPage> createState() =>
      MemberSearchChildPageState();
}

class MemberSearchChildPageState
    extends ScopedSearchPageState<MemberSearchChildPage>
    with DynMixin, GridMixin {
  @override
  ScopedSearchQuery queryFor(MemberSearchChildPage widget) => (
    kind: widget.searchType == MemberSearchType.archive
        ? ScopedSearchKind.archive
        : ScopedSearchKind.dynamic,
    keyword: widget.keyword,
    mid: widget.mid,
    owner: widget.owner,
  );
  @override
  EdgeInsets get contentPadding => EdgeInsets.only(
    top: widget.searchType == MemberSearchType.archive ? 7 : 0,
  );

  @override
  Widget wrapResults(Widget sliver) =>
      widget.searchType == MemberSearchType.dynamic
      ? buildPage(sliver)
      : sliver;

  @override
  Widget get buildLoading {
    return switch (widget.searchType) {
      MemberSearchType.archive => gridSkeleton,
      MemberSearchType.dynamic => dynSkeleton,
    };
  }

  @override
  Widget buildBody(List response) {
    return response.isNotEmpty
        ? switch (widget.searchType) {
            MemberSearchType.archive => SliverGrid.builder(
              gridDelegate: gridDelegate,
              itemBuilder: (context, index) {
                return SearchArchiveGrpc(item: response[index]);
              },
              itemCount: response.length,
            ),
            MemberSearchType.dynamic =>
              GlobalData().dynamicsWaterfallFlow
                  ? SliverWaterfallFlow(
                      gridDelegate: dynGridDelegate,
                      delegate: SliverChildBuilderDelegate(
                        (_, index) => _itemBuilder(response, index),
                        childCount: response.length,
                      ),
                    )
                  : SliverList.builder(
                      itemBuilder: (context, index) =>
                          _itemBuilder(response, index),
                      itemCount: response.length,
                    ),
          }
        : HttpError(onReload: reload);
  }

  Widget _itemBuilder(List list, int index) {
    return DynamicPanel(item: list[index]);
  }
}
