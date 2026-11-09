import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/utils/grid.dart' as grid;

SliverConstraints _constraints(double width, AxisDirection direction) =>
    SliverConstraints(
      axisDirection: AxisDirection.down,
      growthDirection: GrowthDirection.forward,
      userScrollDirection: ScrollDirection.idle,
      scrollOffset: 0,
      precedingScrollExtent: 0,
      overlap: 0,
      remainingPaintExtent: 800,
      crossAxisExtent: width,
      crossAxisDirection: direction,
      viewportMainAxisExtent: 800,
      remainingCacheExtent: 800,
      cacheOrigin: 0,
    );

void main() {
  test('可通过标准委托接口比较布局配置', () {
    final SliverGridDelegateWithMaxCrossAxisExtent delegate =
        grid.SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 240);
    expect(
      delegate.shouldRelayout(
        const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 240),
      ),
      isFalse,
    );
    expect(
      delegate.shouldRelayout(
        const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 480),
      ),
      isTrue,
    );
  });

  test('缓存网格在缩放和方向切换后保持标准几何与滚动范围', () {
    for (final extent in <double?>[null, 110]) {
      final delegate = grid.SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 240,
        mainAxisSpacing: 2,
        crossAxisSpacing: 4,
        childAspectRatio: 1.6,
        mainAxisExtent: extent,
      );
      final standard = SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 240,
        mainAxisSpacing: 2,
        crossAxisSpacing: 4,
        childAspectRatio: 1.6,
        mainAxisExtent: extent,
      );
      for (final width in <double>[200, 500, 1000, 200]) {
        for (final direction in [AxisDirection.right, AxisDirection.left]) {
          final constraints = _constraints(width, direction);
          final layout = delegate.getLayout(constraints);
          final expected = standard.getLayout(constraints);
          expect(delegate.getLayout(constraints), same(layout));
          expect(delegate.layoutCache, same(layout));
          expect(
            layout.computeMaxScrollOffset(37),
            expected.computeMaxScrollOffset(37),
          );
          for (final index in [0, 1, 12, 36]) {
            final actual = layout.getGeometryForChildIndex(index);
            final target = expected.getGeometryForChildIndex(index);
            expect(
              (
                actual.scrollOffset,
                actual.crossAxisOffset,
                actual.mainAxisExtent,
                actual.crossAxisExtent,
              ),
              (
                target.scrollOffset,
                target.crossAxisOffset,
                target.mainAxisExtent,
                target.crossAxisExtent,
              ),
            );
          }
        }
      }
    }
  });
}
