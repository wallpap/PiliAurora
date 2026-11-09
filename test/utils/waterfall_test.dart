import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/utils/waterfall.dart';
import 'package:waterfall_flow/waterfall_flow.dart' as waterfall;

SliverConstraints _constraints(double width) => SliverConstraints(
  axisDirection: AxisDirection.down,
  growthDirection: GrowthDirection.forward,
  userScrollDirection: ScrollDirection.idle,
  scrollOffset: 0,
  precedingScrollExtent: 0,
  overlap: 0,
  remainingPaintExtent: 800,
  crossAxisExtent: width,
  crossAxisDirection: AxisDirection.right,
  viewportMainAxisExtent: 800,
  remainingCacheExtent: 800,
  cacheOrigin: 0,
);

void main() {
  test('列数随宽度跨过边界变化，重复读取保持一致', () {
    final delegate = SliverWaterfallFlowDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 150,
      crossAxisSpacing: 10,
    );
    expect(delegate.getCrossAxisCount(_constraints(320)), 2);
    expect(delegate.getCrossAxisCount(_constraints(320)), 2);
    expect(delegate.getCrossAxisCount(_constraints(321)), 3);
    expect(delegate.getCrossAxisCount(_constraints(160)), 1);
  });

  test('布局参数变化或委托类型变化时失效缓存', () {
    final original = SliverWaterfallFlowDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 150,
      crossAxisSpacing: 10,
    );
    final same = SliverWaterfallFlowDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 150,
      crossAxisSpacing: 10,
    );
    final spacing = SliverWaterfallFlowDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 150,
      crossAxisSpacing: 20,
    );
    final extent = SliverWaterfallFlowDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: 200,
      crossAxisSpacing: 10,
    );
    expect(original.getCrossAxisCount(_constraints(320)), 2);
    expect(original.shouldRelayout(same), isFalse);
    expect(original.crossAxisCount, 2);
    expect(original.shouldRelayout(spacing), isTrue);
    expect(original.crossAxisCount, isNull);
    expect(original.getCrossAxisCount(_constraints(320)), 2);
    expect(original.shouldRelayout(extent), isTrue);
    expect(original.crossAxisCount, isNull);
    expect(original.getCrossAxisCount(_constraints(320)), 2);
    expect(
      original.shouldRelayout(
        const waterfall.SliverWaterfallFlowDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 150,
          crossAxisSpacing: 10,
        ),
      ),
      isTrue,
    );
    expect(original.crossAxisCount, isNull);
  });
}
