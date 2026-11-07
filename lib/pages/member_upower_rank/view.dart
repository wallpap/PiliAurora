import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/utils/extension/scroll_controller_ext.dart';
import 'package:pili_aurora/common/widgets/flutter/list_tile.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/keep_alive_wrapper.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart' show tabBarView;
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/image_type.dart';
import 'package:pili_aurora/models/remote/upower_rank/rank_info.dart';
import 'package:pili_aurora/pages/member_upower_rank/controller.dart';
import 'package:pili_aurora/utils/extension/widget_ext.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart' hide ListTile;

class UpowerRankPage extends ConsumerStatefulWidget {
  const UpowerRankPage({
    super.key,
    this.privilegeType,
    this.upMid,
    this.scrollController,
  });

  final int? privilegeType;
  final String? upMid;
  final ScrollController? scrollController;

  @override
  ConsumerState<UpowerRankPage> createState() => _UpowerRankPageState();

  static Future<void>? toUpowerRank({
    required Object mid,
    required String name,
    required Object? count,
  }) {
    return Get.toNamed(
      '/upowerRank',
      arguments: {
        'mid': mid,
        'name': name,
        'count': count,
      },
    );
  }
}

class _UpowerRankPageState extends ConsumerState<UpowerRankPage>
    with AutomaticKeepAliveClientMixin {
  String? _name;
  Object? _count;
  late final String _upMid;
  final _owner = Object();
  final _childScrolls = <int?, ScrollController>{};
  late final _scroll = widget.scrollController ?? ScrollController();
  UpowerRankQuery get _query =>
      (mid: _upMid, privilege: widget.privilegeType, owner: _owner);
  Future<void> _reload() async {
    ref.invalidate(upowerRankingProvider(_query));
    try {
      await ref.read(upowerRankingProvider(_query).future);
    } catch (_) {
      /* 页面展示错误。 */
    }
  }

  @override
  void dispose() {
    if (widget.scrollController == null) _scroll.dispose();
    for (final scroll in _childScrolls.values) {
      scroll.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final params = widget.upMid == null ? Get.arguments : null;
    _upMid = widget.upMid ?? params['mid']!.toString();
    if (widget.privilegeType == null && params != null) {
      _name = params['name'];
      _count = params['count'];
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final snapshot = ref.watch(upowerRankingProvider(_query));
    final data = !snapshot.isLoading && !snapshot.hasError
        ? snapshot.value
        : null;
    final theme = Theme.of(context);
    final padding = MediaQuery.viewPaddingOf(context);
    final child = refreshIndicator(
      onRefresh: _reload,
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.only(bottom: padding.bottom + 100),
            sliver: snapshot.when(
              skipLoadingOnRefresh: false,
              skipLoadingOnReload: false,
              loading: () => const SliverFillRemaining(child: m3eLoading),
              error: (error, _) =>
                  HttpError(errMsg: error.toString(), onReload: _reload),
              data: (data) => _buildBody(theme, Success(data.ranks)),
            ),
          ),
        ],
      ),
    );
    if (widget.privilegeType == null) {
      return SimpleScaffold(
        appBar: AppBar(
          title: Text('$_name的充电排行榜${_count == null ? '' : '($_count)'}'),
          actions: [
            TextButton(
              onPressed: () => Get.toNamed(
                '/webview',
                parameters: {
                  'url':
                      'https://member.bilibili.com/mall/upower-pay?mid=$_upMid&oid=$_upMid',
                },
              ),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: const Text('充电'),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: Padding(
          padding: EdgeInsets.only(left: padding.left, right: padding.right),
          child: Builder(
            builder: (_) {
              final tabs = data != null && data.levels.length > 1
                  ? data.levels
                  : null;
              return tabs != null
                  ? DefaultTabController(
                      key: ValueKey(tabs.map((e) => e.privilegeType).join(',')),
                      length: tabs.length,
                      child: Builder(
                        builder: (context) {
                          return Column(
                            children: [
                              TabBar(
                                isScrollable: true,
                                tabAlignment: TabAlignment.start,
                                tabs: tabs
                                    .map(
                                      (e) => Tab(
                                        text:
                                            '${e.name!}(${e.memberTotal ?? 0})',
                                      ),
                                    )
                                    .toList(),
                                onTap: (index) {
                                  if (!DefaultTabController.of(
                                    context,
                                  ).indexIsChanging) {
                                    if (index == 0) {
                                      _scroll.animToTop();
                                    } else {
                                      _childScrolls[tabs[index].privilegeType]
                                          ?.animToTop();
                                    }
                                  }
                                },
                              ),
                              Expanded(
                                child: tabBarView(
                                  children: [
                                    KeepAliveWrapper(child: child),
                                    ...tabs
                                        .skip(1)
                                        .map(
                                          (e) => UpowerRankPage(
                                            key: ValueKey(e.privilegeType),
                                            privilegeType: e.privilegeType,
                                            upMid: _upMid,
                                            scrollController: _childScrolls
                                                .putIfAbsent(
                                                  e.privilegeType,
                                                  ScrollController.new,
                                                ),
                                          ),
                                        ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    )
                  : child;
            },
          ),
        ).constraintWidth(),
      );
    } else {
      return child;
    }
  }

  Widget _buildBody(
    ThemeData theme,
    LoadingState<List<UpowerRankInfo>?> loadingState,
  ) {
    late final width = MediaQuery.textScalerOf(context).scale(32);
    return switch (loadingState) {
      Loading() => const SliverFillRemaining(child: m3eLoading),
      Success<List<UpowerRankInfo>?>(:final response) =>
        response != null && response.isNotEmpty
            ? SliverList.builder(
                itemCount: response.length,
                itemBuilder: (context, index) {
                  final item = response[index];
                  return Material(
                    type: MaterialType.transparency,
                    child: ListTile(
                      onTap: () => Get.toNamed('/member?mid=${item.mid}'),
                      leading: SizedBox(
                        width: width,
                        child: Center(
                          child: Text(
                            (index + 1).toString(),
                            style: TextStyle(
                              fontSize: 16,
                              fontStyle: FontStyle.italic,
                              fontWeight: FontWeight.bold,
                              color: switch (index) {
                                0 => const Color(0xFFfdad13),
                                1 => const Color(0xFF8aace1),
                                2 => const Color(0xFFdfa777),
                                _ => theme.colorScheme.outline,
                              },
                            ),
                          ),
                        ),
                      ),
                      title: Row(
                        spacing: 12,
                        children: [
                          NetworkImgLayer(
                            width: 38,
                            height: 38,
                            src: item.avatar,
                            type: ImageType.avatar,
                          ),
                          Text(
                            item.nickname!,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ],
                      ),
                      trailing: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: item.day!.toString(),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const TextSpan(
                              text: ' 天',
                              style: TextStyle(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              )
            : HttpError(onReload: _reload),
      Error(:final errMsg) => HttpError(
        errMsg: errMsg,
        onReload: _reload,
      ),
    };
  }

  @override
  bool get wantKeepAlive => widget.privilegeType != null;
}
