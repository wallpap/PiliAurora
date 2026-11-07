import 'package:pili_aurora/common/skeleton/msg_feed_top.dart';
import 'package:pili_aurora/common/skeleton/video_card_v.dart';
import 'package:pili_aurora/common/sliver_single_child_delegate.dart';
import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/models/common/live/live_search_type.dart';
import 'package:pili_aurora/pages/live_search/widgets/live_search_room.dart';
import 'package:pili_aurora/pages/live_search/widgets/live_search_user.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/pages/common/search/scoped_search.dart';
import 'package:pili_aurora/pages/common/search/scoped_search_page.dart';
import 'package:material_ui/material_ui.dart'
    hide SliverGridDelegateWithMaxCrossAxisExtent;

class LiveSearchChildPage extends ConsumerStatefulWidget {
  const LiveSearchChildPage({
    super.key,
    required this.keyword,
    required this.owner,
    this.mid,
    required this.searchType,
  });

  final String keyword;
  final Object owner;
  final int? mid;
  final LiveSearchType searchType;

  @override
  ConsumerState<LiveSearchChildPage> createState() =>
      LiveSearchChildPageState();
}

class LiveSearchChildPageState
    extends ScopedSearchPageState<LiveSearchChildPage> {
  @override
  ScopedSearchQuery queryFor(LiveSearchChildPage widget) => (
    kind: widget.searchType == LiveSearchType.room
        ? ScopedSearchKind.room
        : ScopedSearchKind.user,
    keyword: widget.keyword,
    mid: widget.mid,
    owner: widget.owner,
  );
  @override
  EdgeInsets get contentPadding => EdgeInsets.only(
    top: widget.searchType == LiveSearchType.room ? 12 : 0,
    left: widget.searchType == LiveSearchType.room ? 12 : 0,
    right: widget.searchType == LiveSearchType.room ? 12 : 0,
  );

  @override
  Widget get buildLoading {
    return switch (widget.searchType) {
      LiveSearchType.room => SliverGrid(
        gridDelegate: SliverGridDelegateWithExtentAndRatio(
          mainAxisSpacing: Style.cardSpace,
          crossAxisSpacing: Style.cardSpace,
          maxCrossAxisExtent: Grid.smallCardWidth,
          childAspectRatio: Style.aspectRatio,
          mainAxisExtent: MediaQuery.textScalerOf(context).scale(72),
        ),
        delegate: const SliverSingleChildDelegate(
          count: 10,
          child: VideoCardVSkeleton(),
        ),
      ),
      LiveSearchType.user => SliverGrid(
        gridDelegate: userDelegate,
        delegate: const SliverSingleChildDelegate(
          count: 12,
          child: MsgFeedTopSkeleton(),
        ),
      ),
    };
  }

  late final roomDelegate = SliverGridDelegateWithExtentAndRatio(
    mainAxisSpacing: Style.cardSpace,
    crossAxisSpacing: Style.cardSpace,
    maxCrossAxisExtent: Grid.smallCardWidth,
    childAspectRatio: Style.aspectRatio,
    mainAxisExtent: MediaQuery.textScalerOf(context).scale(60),
  );

  late final userDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: Grid.smallCardWidth * 2,
    mainAxisExtent: 60,
  );

  @override
  Widget buildBody(List response) {
    return response.isNotEmpty
        ? switch (widget.searchType) {
            LiveSearchType.room => SliverGrid.builder(
              gridDelegate: roomDelegate,
              itemBuilder: (context, index) =>
                  LiveCardVSearch(item: response[index]),
              itemCount: response.length,
            ),
            LiveSearchType.user => SliverGrid.builder(
              gridDelegate: userDelegate,
              itemBuilder: (context, index) =>
                  LiveSearchUserItem(item: response[index]),
              itemCount: response.length,
            ),
          }
        : HttpError(onReload: reload);
  }
}
