import 'package:pili_aurora/common/skeleton/video_card_v.dart';
import 'package:pili_aurora/common/sliver_single_child_delegate.dart';
import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/common/widgets/feed_pagination.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/video_card/video_card_v.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/rcmd/controller.dart';
import 'package:pili_aurora/pages/rcmd/viewport.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class RcmdPage extends StatefulWidget {
  const RcmdPage({super.key});

  @override
  State<RcmdPage> createState() => _RcmdPageState();
}

class _RcmdPageState extends State<RcmdPage>
    with AutomaticKeepAliveClientMixin {
  final controller = Get.put(RcmdController());

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colorScheme = ColorScheme.of(context);
    return Container(
      clipBehavior: .hardEdge,
      margin: const .symmetric(horizontal: Style.safeSpace),
      decoration: const BoxDecoration(borderRadius: Style.mdRadius),
      child: RcmdViewport(
        onChanged: (items, columns, active) => controller.updateViewport(
          itemCount: items,
          columns: columns,
          active: active,
        ),
        builder: (gridDelegate, items, rowStride) => refreshIndicator(
          onRefresh: controller.onRefresh,
          child: FeedPagination(
            // 两行卡片加列表底部留白，窗口缩放后使用最新网格行高。
            prefetchExtent: () => rowStride * 2 + 100,
            controller: controller.scrollController,
            dataChanges: controller.loadingState.stream,
            canLoadMore: () =>
                controller.canLoadMore &&
                !controller.isLoading &&
                controller.scrollController.hasClients &&
                controller.scrollController.position.pixels > 0,
            onLoadMore: controller.onLoadMore,
            child: CustomScrollView(
              scrollCacheExtent: const ScrollCacheExtent.pixels(0),
              controller: controller.scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: const .only(top: Style.cardSpace),
                  sliver: Obx(
                    () => _buildBody(
                      colorScheme,
                      controller.loadingState.value,
                      gridDelegate,
                      items,
                    ),
                  ),
                ),
                Obx(() {
                  final state = controller.loadingState.value;
                  final error = controller.loadMoreError;
                  return SliverToBoxAdapter(
                    child: SizedBox(
                      height: 100,
                      child:
                          state.dataOrNull?.isNotEmpty == true && error != null
                          ? Center(
                              child: TextButton.icon(
                                onPressed: controller.retryLoadMore,
                                icon: const Icon(Icons.refresh),
                                label: const Text('加载失败，点击重试'),
                              ),
                            )
                          : null,
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    ColorScheme colorScheme,
    LoadingState<List<dynamic>?> loadingState,
    SliverGridDelegateWithExtentAndRatio gridDelegate,
    int skeletonItems,
  ) {
    return switch (loadingState) {
      Loading() => _buildSkeleton(gridDelegate, skeletonItems),
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemBuilder: (context, index) {
                  if (controller.lastRefreshAt != null) {
                    if (controller.lastRefreshAt == index) {
                      return GestureDetector(
                        onTap: () => controller
                          ..animateToTop()
                          ..onRefresh(),
                        child: Card(
                          child: Container(
                            alignment: Alignment.center,
                            padding: const .symmetric(horizontal: 10),
                            child: Text(
                              '上次看到这里\n点击刷新',
                              textAlign: .center,
                              style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      );
                    }
                    final actualIndex = index > controller.lastRefreshAt!
                        ? index - 1
                        : index;
                    if (controller.isPending(response[actualIndex])) {
                      return const VideoCardVSkeleton();
                    }
                    return VideoCardV(
                      videoItem: response[actualIndex],
                      onRemove: () {
                        controller.removeRecommendation(response[actualIndex]);
                      },
                    );
                  } else {
                    if (controller.isPending(response[index])) {
                      return const VideoCardVSkeleton();
                    }
                    return VideoCardV(
                      videoItem: response[index],
                      onRemove: () =>
                          controller.removeRecommendation(response[index]),
                    );
                  }
                },
                itemCount: controller.lastRefreshAt != null
                    ? response.length + 1
                    : response.length,
              )
            : controller.isLoading
            ? _buildSkeleton(gridDelegate, skeletonItems)
            : HttpError(onReload: controller.onReload),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: controller.onReload,
      ),
    };
  }

  Widget _buildSkeleton(
    SliverGridDelegateWithExtentAndRatio delegate,
    int items,
  ) => SliverGrid(
    gridDelegate: delegate,
    delegate: SliverSingleChildDelegate(
      count: items,
      child: const VideoCardVSkeleton(),
    ),
  );
}
