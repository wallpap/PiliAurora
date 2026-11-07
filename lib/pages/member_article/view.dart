import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/space/space_article/item.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/pages/common/member_feed.dart';
import 'package:pili_aurora/pages/common/member_feed_view.dart';
import 'package:pili_aurora/pages/member_article/widget/item.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:material_ui/material_ui.dart';

class MemberArticle extends ConsumerStatefulWidget {
  const MemberArticle({
    super.key,
    required this.heroTag,
    required this.mid,
  });

  final String? heroTag;
  final int mid;

  @override
  ConsumerState<MemberArticle> createState() => _MemberArticleState();
}

class _MemberArticleState extends ConsumerState<MemberArticle>
    with
        AutomaticKeepAliveClientMixin,
        GridMixin,
        MemberFeedView<MemberArticle, SpaceArticleItem> {
  @override
  MemberFeedKind get feedKind => MemberFeedKind.article;
  @override
  Object get feedMid => widget.mid;
  @override
  bool get wantKeepAlive => true;

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

  Widget _buildBody(LoadingState<List<SpaceArticleItem>?> loadingState) {
    return switch (loadingState) {
      Loading() => gridSkeleton,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemBuilder: (context, index) {
                  return MemberArticleItem(
                    item: response[index],
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
