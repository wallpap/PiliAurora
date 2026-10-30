import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pili_aurora/common/style.dart';
import 'package:pili_aurora/utils/grid.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

/// 容量与卡片共用网格几何，底部导航留白不计入可见内容高度。
class RcmdViewport extends StatelessWidget {
  const RcmdViewport({
    super.key,
    required this.onChanged,
    required this.builder,
  });

  final void Function(int items, int columns, bool active) onChanged;
  final Widget Function(
    SliverGridDelegateWithExtentAndRatio delegate,
    int items,
    double rowStride,
  )
  builder;

  @override
  Widget build(BuildContext context) {
    final active = TickerMode.valuesOf(context).enabled;
    final textHeight = MediaQuery.textScalerOf(context).scale(90);
    return LayoutBuilder(
      builder: (context, constraints) {
        final delegate = SliverGridDelegateWithExtentAndRatio(
          mainAxisSpacing: Style.cardSpace,
          crossAxisSpacing: Style.cardSpace,
          maxCrossAxisExtent: Pref.recommendCardWidth,
          childAspectRatio: Style.aspectRatio,
          mainAxisExtent: textHeight,
        );
        final layout = delegate.layoutForWidth(
          math.max(1, constraints.maxWidth),
        );
        final height = math.max(0.0, constraints.maxHeight - Style.cardSpace);
        final rows = ((height + Style.cardSpace) / layout.mainAxisStride)
            .ceil();
        final items = (rows + 1) * layout.crossAxisCount;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted) onChanged(items, layout.crossAxisCount, active);
        });
        return builder(delegate, items, layout.mainAxisStride);
      },
    );
  }
}
