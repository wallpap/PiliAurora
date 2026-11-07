import 'package:pili_aurora/common/widgets/flutter/list_tile.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/view_sliver_safe_area.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/member_guard/guard_top_list.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/pages/common/member_feed.dart';
import 'package:pili_aurora/pages/common/member_feed_view.dart';
import 'package:pili_aurora/utils/bili_utils.dart';
import 'package:pili_aurora/utils/color_utils.dart';
import 'package:pili_aurora/utils/extension/widget_ext.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart' hide ListTile;

class MemberGuard extends ConsumerStatefulWidget {
  const MemberGuard({super.key}) : ruid = null;

  const MemberGuard.panel({super.key, required this.ruid});

  final Object? ruid;

  @override
  ConsumerState<MemberGuard> createState() => _MemberGuardState();

  static Future<void>? toMemberGuard({
    required Object mid,
    required String name,
    required Object? count,
  }) {
    return Get.toNamed(
      '/memberGuard',
      arguments: {
        'ruid': mid,
        'name': name,
        'count': count,
      },
    );
  }
}

class _MemberGuardState extends ConsumerState<MemberGuard>
    with MemberFeedView<MemberGuard, GuardItem> {
  @override
  MemberFeedKind get feedKind => MemberFeedKind.guard;
  @override
  Object get feedMid => _ruid;
  late final String _userName;
  late final Object? _count;
  late final Object _ruid;

  @override
  void initState() {
    super.initState();
    final args = widget.ruid == null ? Get.arguments : null;
    _userName = widget.ruid == null ? args['name'] : '';
    _count = widget.ruid == null ? args['count'] : null;
    _ruid = widget.ruid ?? args['ruid'];
  }

  @override
  Widget build(BuildContext context) {
    final title = '$_userName的舰队${_count == null ? '' : '($_count)'}';
    final body = refreshIndicator(
      onRefresh: reloadFeed,
      child: paginateFeed(
        CustomScrollView(
          slivers: [
            ViewSliverSafeArea(
              sliver: watchFeed(_buildBody),
            ),
            feedFooter,
          ],
        ),
      ),
    ).constraintWidth();
    if (widget.ruid != null) return body;
    return SimpleScaffold(
      appBar: AppBar(title: Text(title)),
      body: body,
    );
  }

  Widget _buildBody(LoadingState<List<GuardItem>?> state) {
    switch (state) {
      case Loading():
        return linearLoading;
      case Success<List<GuardItem>?>(:final response):
        return SliverMainAxisGroup(
          slivers: [
            _buildTopItems(),
            if (response!.isNotEmpty)
              SliverPadding(
                padding: const .only(top: 10),
                sliver: SliverList.separated(
                  itemCount: response.length,
                  itemBuilder: (context, index) {
                    final item = response[index];
                    return ListTile(
                      safeArea: false,
                      visualDensity: .comfortable,
                      onTap: () => Get.toNamed('/member?mid=${item.uid}'),
                      leading: Row(
                        mainAxisSize: .min,
                        spacing: 10,
                        children: [
                          SizedBox(
                            width: 32,
                            child: Center(
                              child: _rank(index + feedData!.tops.length + 1),
                            ),
                          ),
                          _avatar(item.face, 32, item.guardLevel),
                        ],
                      ),
                      title: Text(
                        item.username,
                        style: const TextStyle(fontSize: 14),
                      ),
                    );
                  },
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                ),
              ),
          ],
        );
      case Error(:final errMsg):
        return HttpError(errMsg: errMsg, onReload: reloadFeed);
    }
  }

  Widget _buildTopItem(GuardItem item, double size, int rank) {
    final child = GestureDetector(
      behavior: .opaque,
      onTap: () => Get.toNamed('/member?mid=${item.uid}'),
      child: Padding(
        padding: const .symmetric(vertical: 10.0),
        child: Column(
          spacing: 5,
          mainAxisSize: .min,
          children: [
            SizedBox(
              height: 67.5, // 50 * 1.35
              child: Align(
                alignment: .bottomCenter,
                child: _avatar(item.face, size, item.guardLevel),
              ),
            ),
            _rank(rank),
            Text(item.username, maxLines: 1, overflow: .ellipsis),
          ],
        ),
      ),
    );
    if (PlatformUtils.isDesktop) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: child,
      );
    }
    return child;
  }

  Widget _rank(int rank) => Text(
    '$rank',
    style: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.bold,
      fontStyle: FontStyle.italic,
      color: ColourUtils.index2Color(rank - 1, ColorScheme.of(context).outline),
    ),
  );

  Widget _buildTopItems() {
    final Widget first;
    final Widget second;
    final Widget third;
    if (feedData!.tops.firstOrNull case final item?) {
      first = _buildTopItem(item, 50, 1);
    } else {
      first = const SizedBox.shrink();
    }
    if (feedData!.tops.elementAtOrNull(1) case final item?) {
      second = _buildTopItem(item, 42, 2);
    } else {
      second = const SizedBox.shrink();
    }
    if (feedData!.tops.elementAtOrNull(2) case final item?) {
      third = _buildTopItem(item, 42, 3);
    } else {
      third = const SizedBox.shrink();
    }
    return SliverToBoxAdapter(
      child: Row(
        children: [
          Expanded(child: second),
          Expanded(child: first),
          Expanded(child: third),
        ],
      ),
    );
  }

  static Widget _avatar(String url, double size, int guardLevel) {
    final pendentSize = 1.35 * size;
    return Stack(
      clipBehavior: .none,
      alignment: .center,
      children: [
        NetworkImgLayer(
          src: url,
          width: size,
          height: size,
          type: .avatar,
        ),
        NetworkImgLayer(
          type: .emote,
          width: pendentSize,
          height: pendentSize,
          src: BiliUtils.liveGuardPendant(guardLevel),
          getPlaceHolder: () => const SizedBox.shrink(),
        ),
      ],
    );
  }
}
