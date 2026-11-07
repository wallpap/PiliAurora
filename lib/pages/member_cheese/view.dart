import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/space/space_cheese/item.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/pages/common/member_feed.dart';
import 'package:pili_aurora/pages/common/member_feed_view.dart';
import 'package:pili_aurora/pages/member_cheese/widgets/item.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:material_ui/material_ui.dart';

class MemberCheese extends ConsumerStatefulWidget {
  const MemberCheese({
    super.key,
    required this.heroTag,
    required this.mid,
  });

  final String? heroTag;
  final int mid;

  @override
  ConsumerState<MemberCheese> createState() => _MemberCheeseState();
}

class _MemberCheeseState extends ConsumerState<MemberCheese>
    with
        AutomaticKeepAliveClientMixin,
        GridMixin,
        MemberFeedView<MemberCheese, SpaceCheeseItem> {
  @override
  MemberFeedKind get feedKind => MemberFeedKind.cheese;
  @override
  Object get feedMid => widget.mid;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return refreshIndicator(
      isClampingScrollPhysics: true,
      onRefresh: reloadFeed,
      child: paginateFeed(
        CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.only(
                top: 7,
                bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
              ),
              sliver: watchFeed(_buildBody),
            ),
            feedFooter,
          ],
        ),
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;

  Widget _buildBody(LoadingState<List<SpaceCheeseItem>?> loadingState) {
    return switch (loadingState) {
      Loading() => gridSkeleton,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemBuilder: (context, index) {
                  return MemberCheeseItem(item: response[index]);
                },
                itemCount: response.length,
              )
            : HttpError(onReload: reloadFeed),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: reloadFeed,
      ),
    };
  }
}
