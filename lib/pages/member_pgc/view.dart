import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart'
    show m3eLoading;
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/space/space_archive/item.dart';
import 'package:pili_aurora/pages/member_pgc/controller.dart';
import 'package:pili_aurora/pages/member_pgc/widgets/pgc_card_v_member_pgc.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class MemberBangumi extends StatefulWidget {
  const MemberBangumi({
    super.key,
    required this.heroTag,
    required this.mid,
  });

  final String? heroTag;
  final int mid;

  @override
  State<MemberBangumi> createState() => _MemberBangumiState();
}

class _MemberBangumiState extends State<MemberBangumi>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late MemberBangumiCtr _controller;

  @override
  void initState() {
    super.initState();
    _controller = MemberBangumiCtr(heroTag: widget.heroTag, mid: widget.mid)
      ..onStart();
  }

  @override
  void didUpdateWidget(MemberBangumi oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mid != widget.mid || oldWidget.heroTag != widget.heroTag) {
      _controller.onDelete();
      _controller = MemberBangumiCtr(heroTag: widget.heroTag, mid: widget.mid)
        ..onStart();
    }
  }

  @override
  void dispose() {
    _controller.onDelete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return refreshIndicator(
      isClampingScrollPhysics: true,
      onRefresh: _controller.onRefresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.only(
              left: Style.safeSpace,
              right: Style.safeSpace,
              top: Style.safeSpace,
              bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
            ),
            sliver: Obx(
              () => _buildBody(_controller.loadingState.value),
            ),
          ),
          Obx(() {
            final error = _controller.paginationError.value;
            if (error == null) return const SliverToBoxAdapter();
            return SliverToBoxAdapter(
              child: TextButton(
                onPressed: _controller.onLoadMore,
                child: Text('$error，点击重试'),
              ),
            );
          }),
        ],
      ),
    );
  }

  late final gridDelegate = SliverGridDelegateWithExtentAndRatio(
    mainAxisSpacing: Style.cardSpace,
    crossAxisSpacing: Style.cardSpace,
    maxCrossAxisExtent: Grid.smallCardWidth * 0.6,
    childAspectRatio: 0.75,
    mainAxisExtent: MediaQuery.textScalerOf(context).scale(52),
  );

  Widget _buildBody(LoadingState<List<SpaceArchiveItem>?> loadingState) {
    return switch (loadingState) {
      Loading() => const SliverToBoxAdapter(
        child: SizedBox(height: 125, child: m3eLoading),
      ),
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? SliverGrid.builder(
                gridDelegate: gridDelegate,
                itemBuilder: (context, index) {
                  if (index == response.length - 1 &&
                      _controller.paginationError.value == null) {
                    _controller.onLoadMore();
                  }
                  return PgcCardVMemberPgc(
                    item: response[index],
                  );
                },
                itemCount: response.length,
              )
            : HttpError(onReload: _controller.onReload),
      Error error => HttpError(
        errMsg: error.toString(),
        onReload: _controller.onReload,
      ),
    };
  }
}
