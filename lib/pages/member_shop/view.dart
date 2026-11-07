import 'package:pili_aurora/common/skeleton/space_opus.dart';
import 'package:pili_aurora/common/sliver_single_child_delegate.dart';
import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/space/space_shop/item.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/pages/common/member_feed.dart';
import 'package:pili_aurora/pages/common/member_feed_view.dart';
import 'package:pili_aurora/pages/member_shop/widgets/item.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:pili_aurora/utils/waterfall.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:waterfall_flow/waterfall_flow.dart'
    hide SliverWaterfallFlowDelegateWithMaxCrossAxisExtent;

class MemberShop extends ConsumerStatefulWidget {
  const MemberShop({
    super.key,
    required this.heroTag,
    required this.mid,
  });

  final String? heroTag;
  final int mid;

  @override
  ConsumerState<MemberShop> createState() => _MemberShopState();
}

class _MemberShopState extends ConsumerState<MemberShop>
    with
        AutomaticKeepAliveClientMixin,
        MemberFeedView<MemberShop, SpaceShopItem> {
  @override
  MemberFeedKind get feedKind => MemberFeedKind.shop;
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
                top: 12,
                left: Style.safeSpace,
                right: Style.safeSpace,
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

  late final gridDelegate = SliverWaterfallFlowDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: Grid.smallCardWidth,
    mainAxisSpacing: Style.safeSpace,
    crossAxisSpacing: Style.safeSpace,
  );

  Widget _buildBody(LoadingState<List<SpaceShopItem>?> loadingState) {
    switch (loadingState) {
      case Loading():
        return SliverWaterfallFlow(
          gridDelegate: gridDelegate,
          delegate: const SliverSingleChildDelegate(
            count: 10,
            child: SpaceOpusSkeleton(),
          ),
        );
      case Success(:final response):
        if (response == null || response.isEmpty) {
          return HttpError(onReload: reloadFeed);
        }
        Widget sliver = SliverWaterfallFlow(
          gridDelegate: gridDelegate,
          delegate: SliverChildBuilderDelegate(
            (_, index) {
              return MemberShopItem(item: response[index]);
            },
            childCount: response.length,
          ),
        );
        if (feedData?.shop?.showMoreTab == true) {
          sliver = SliverMainAxisGroup(
            slivers: [
              sliver,
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 25),
                  child: Center(
                    child: FilledButton.tonal(
                      onPressed: () {
                        if (feedData?.shop?.clickUrl case final clickUrl?) {
                          final url = Uri.parse(
                            clickUrl,
                          ).queryParameters['url'];
                          if (url case final url?) {
                            Get.toNamed(
                              '/webview',
                              parameters: {'url': url},
                            );
                          }
                        }
                      },
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      child: Text(feedData?.shop?.showMoreDesc ?? ''),
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        return sliver;
      case Error(:final errMsg):
        return HttpError(
          errMsg: errMsg,
          onReload: reloadFeed,
        );
    }
  }
}
