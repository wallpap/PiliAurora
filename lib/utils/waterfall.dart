import 'package:pili_aurora/common/skeleton/dynamic_card.dart';
import 'package:pili_aurora/common/sliver_single_child_delegate.dart';
import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/common/widgets/sliver/sliver_constrained_cross_axis.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:flutter/rendering.dart' show SliverConstraints;
import 'package:material_ui/material_ui.dart';
import 'package:waterfall_flow/waterfall_flow.dart' as waterfall;

mixin DynMixin {
  late final dynGridDelegate =
      SliverWaterfallFlowDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: Grid.smallCardWidth * 2,
        crossAxisSpacing: 4,
      );

  Widget buildPage(Widget child) {
    if (GlobalData().dynamicsWaterfallFlow) {
      return child;
    }
    return CenteredSliverConstrainedCrossAxis(
      maxExtent: Grid.smallCardWidth * 2,
      sliver: child,
    );
  }

  late final skeDelegate = SliverGridDelegateWithExtentAndRatio(
    crossAxisSpacing: 4,
    mainAxisSpacing: 4,
    maxCrossAxisExtent: Grid.smallCardWidth * 2,
    childAspectRatio: Style.aspectRatio,
    mainAxisExtent: 50,
  );

  Widget get dynSkeleton {
    if (GlobalData().dynamicsWaterfallFlow) {
      return SliverGrid(
        gridDelegate: skeDelegate,
        delegate: const SliverSingleChildDelegate(
          count: 10,
          child: DynamicCardSkeleton(),
        ),
      );
    }
    return const SliverPrototypeExtentList(
      prototypeItem: DynamicCardSkeleton(),
      delegate: SliverSingleChildDelegate(
        count: 10,
        child: DynamicCardSkeleton(),
      ),
    );
  }
}

class SliverWaterfallFlowDelegateWithMaxCrossAxisExtent
    extends waterfall.SliverWaterfallFlowDelegateWithMaxCrossAxisExtent {
  SliverWaterfallFlowDelegateWithMaxCrossAxisExtent({
    required super.maxCrossAxisExtent,
    super.mainAxisSpacing,
    super.crossAxisSpacing,
    super.lastChildLayoutTypeBuilder,
    super.collectGarbage,
    super.viewportBuilder,
    super.closeToTrailing,
  });

  int? crossAxisCount;
  double? crossAxisExtent;

  @override
  int getCrossAxisCount(SliverConstraints constraints) {
    final crossAxisExtent = constraints.crossAxisExtent;
    if (crossAxisCount != null && this.crossAxisExtent == crossAxisExtent) {
      return crossAxisCount!;
    }
    this.crossAxisExtent = crossAxisExtent;
    crossAxisCount = super.getCrossAxisCount(constraints);
    return crossAxisCount!;
  }

  @override
  bool shouldRelayout(waterfall.SliverWaterfallFlowDelegate oldDelegate) {
    final flag = super.shouldRelayout(oldDelegate);
    if (flag) {
      crossAxisCount = null;
    }
    return flag;
  }
}
