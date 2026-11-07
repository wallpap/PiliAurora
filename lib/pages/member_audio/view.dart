import 'package:pili_aurora/grpc/bilibili/app/listener/v1.pbenum.dart'
    show PlaylistSource;
import 'package:pili_aurora/pages/audio/view.dart';
import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/sliver/sliver_floating_header.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/space/space_audio/item.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/pages/common/member_feed.dart';
import 'package:pili_aurora/pages/common/member_feed_view.dart';
import 'package:pili_aurora/pages/member_audio/widgets/item.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:material_ui/material_ui.dart';

class MemberAudio extends ConsumerStatefulWidget {
  const MemberAudio({
    super.key,
    required this.heroTag,
    required this.mid,
  });

  final String? heroTag;
  final int mid;

  @override
  ConsumerState<MemberAudio> createState() => _MemberAudioState();
}

class _MemberAudioState extends ConsumerState<MemberAudio>
    with
        AutomaticKeepAliveClientMixin,
        GridMixin,
        MemberFeedView<MemberAudio, SpaceAudioItem> {
  @override
  MemberFeedKind get feedKind => MemberFeedKind.audio;
  @override
  Object get feedMid => widget.mid;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colorScheme = ColorScheme.of(context);
    return refreshIndicator(
      isClampingScrollPhysics: true,
      onRefresh: reloadFeed,
      child: paginateFeed(
        CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
              ),
              sliver: watchFeed((state) => _buildBody(colorScheme, state)),
            ),
            feedFooter,
          ],
        ),
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;

  Widget _buildBody(
    ColorScheme colorScheme,
    LoadingState<List<SpaceAudioItem>?> loadingState,
  ) {
    return switch (loadingState) {
      Loading() => linearLoading,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverMainAxisGroup(
                slivers: [
                  SliverFloatingHeaderWidget(
                    backgroundColor: colorScheme.surface,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 2.5, 8, 2.5),
                      child: Row(
                        children: [
                          Text(
                            '共${feedData?.total ?? 0}首',
                            style: const TextStyle(fontSize: 13),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: TextButton.icon(
                              style: Style.buttonStyle,
                              onPressed: () {
                                final item = response.first;
                                AudioPage.toAudioPage(
                                  itemType: 3,
                                  id: item.uid!,
                                  oid: item.id!,
                                  from: PlaylistSource.MEM_SPACE,
                                );
                              },
                              icon: Icon(
                                Icons.play_circle_outline_rounded,
                                size: 16,
                                color: colorScheme.secondary,
                              ),
                              label: Text(
                                '播放全部',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: colorScheme.secondary,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverGrid.builder(
                    gridDelegate: gridDelegate,
                    itemBuilder: (context, index) {
                      return MemberAudioItem(
                        item: response[index],
                      );
                    },
                    itemCount: response.length,
                  ),
                ],
              )
            : HttpError(onReload: reloadFeed),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: reloadFeed,
      ),
    };
  }
}
