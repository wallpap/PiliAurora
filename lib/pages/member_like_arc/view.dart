import 'package:pili_aurora/common/skeleton/video_card_v.dart';
import 'package:pili_aurora/common/sliver_single_child_delegate.dart';
import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/member/coin_like_arc/item.dart';
import 'package:pili_aurora/pages/member_coin_arc/widgets/item.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/pages/common/member_feed.dart';
import 'package:pili_aurora/pages/common/member_feed_view.dart';
import 'package:pili_aurora/services/account_providers.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:material_ui/material_ui.dart';

class MemberLikeArcPage extends ConsumerStatefulWidget {
  const MemberLikeArcPage({
    super.key,
    required this.mid,
    this.name,
  });

  final dynamic mid;
  final String? name;

  @override
  ConsumerState<MemberLikeArcPage> createState() => _MemberLikeArcPageState();
}

class _MemberLikeArcPageState extends ConsumerState<MemberLikeArcPage>
    with MemberFeedView<MemberLikeArcPage, CoinLikeArcItem> {
  @override
  MemberFeedKind get feedKind => MemberFeedKind.like;
  @override
  Object get feedMid => widget.mid;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    return SimpleScaffold(
      appBar: AppBar(
        title: Text(
          '${widget.mid.toString() == ref.watch(mainAccountProvider).mid.toString() ? '我' : '${widget.name}'}的推荐',
        ),
      ),
      body: refreshIndicator(
        onRefresh: reloadFeed,
        child: paginateFeed(
          CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.only(
                  top: 7,
                  left: Style.safeSpace + padding.left,
                  right: Style.safeSpace + padding.right,
                  bottom: padding.bottom + 100,
                ),
                sliver: watchFeed(_buildBody),
              ),
              feedFooter,
            ],
          ),
        ),
      ),
    );
  }

  late final gridDelegate = SliverGridDelegateWithExtentAndRatio(
    mainAxisSpacing: Style.cardSpace,
    crossAxisSpacing: Style.cardSpace,
    maxCrossAxisExtent: Grid.smallCardWidth,
    childAspectRatio: Style.aspectRatio,
    mainAxisExtent: MediaQuery.textScalerOf(context).scale(75),
  );

  Widget _buildBody(LoadingState<List<CoinLikeArcItem>?> loadingState) {
    return switch (loadingState) {
      Loading() => SliverGrid(
        gridDelegate: gridDelegate,
        delegate: const SliverSingleChildDelegate(
          count: 16,
          child: VideoCardVSkeleton(),
        ),
      ),
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemCount: response.length,
                itemBuilder: (context, index) {
                  return MemberCoinLikeItem(item: response[index]);
                },
              )
            : HttpError(onReload: reloadFeed),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: reloadFeed,
      ),
    };
  }
}
