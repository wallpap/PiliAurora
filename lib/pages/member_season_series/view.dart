import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart';
import 'package:pili_aurora/common/widgets/view_safe_area.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/member/contribute_type.dart';
import 'package:pili_aurora/models/remote/space/space_season_series/season.dart'
    show SpaceSsModel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/pages/common/member_feed.dart';
import 'package:pili_aurora/pages/common/member_feed_view.dart';
import 'package:pili_aurora/pages/member_season_series/widget/season_series_card.dart';
import 'package:pili_aurora/pages/member_video/view.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class SeasonSeriesPage extends ConsumerStatefulWidget {
  const SeasonSeriesPage({
    super.key,
    required this.mid,
    this.heroTag,
  });

  final int mid;
  final String? heroTag;

  @override
  ConsumerState<SeasonSeriesPage> createState() => _SeasonSeriesPageState();
}

class _SeasonSeriesPageState extends ConsumerState<SeasonSeriesPage>
    with
        AutomaticKeepAliveClientMixin,
        GridMixin,
        MemberFeedView<SeasonSeriesPage, SpaceSsModel> {
  @override
  MemberFeedKind get feedKind => MemberFeedKind.series;
  @override
  Object get feedMid => widget.mid;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return paginateFeed(
      CustomScrollView(
        physics: platformAlwaysClampingPhysics,
        slivers: [
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
            ),
            sliver: watchFeed(_buildBody),
          ),
          feedFooter,
        ],
      ),
    );
  }

  Widget _buildBody(LoadingState<List<SpaceSsModel>?> loadingState) {
    return switch (loadingState) {
      Loading() => gridSkeleton,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemBuilder: (context, index) {
                  SpaceSsModel item = response[index];
                  return SeasonSeriesCard(
                    item: item,
                    onTap: () {
                      bool isSeason = item.meta!.seasonId != null;
                      dynamic id = isSeason
                          ? item.meta!.seasonId
                          : item.meta!.seriesId;
                      Get.to(
                        SimpleScaffold(
                          appBar: AppBar(title: Text(item.meta!.name!)),
                          body: ViewSafeArea(
                            child: MemberVideo(
                              type: isSeason
                                  ? ContributeType.season
                                  : ContributeType.series,
                              heroTag: widget.heroTag,
                              mid: widget.mid,
                              seasonId: isSeason ? id : null,
                              seriesId: isSeason ? null : id,
                              title: item.meta!.name,
                            ),
                          ),
                        ),
                      );
                    },
                  );
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
