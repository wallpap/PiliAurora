import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/rcmd/controller.dart';
import 'package:pili_aurora/pages/rcmd/viewport.dart';
import 'package:pili_aurora/utils/storage.dart';

import '../../support/memory_box.dart';

class _Recommendations extends RcmdController {
  _Recommendations(this.now);
  final Duration Function() now;
  final account = Object();
  final starts = <({int index, int milliseconds})>[];
  @override
  Object get queryContext => account;
  @override
  Future<void>? prepareQuery() => null;
  @override
  List<dynamic> filterCandidates(
    Iterable<dynamic> source, {
    Iterable<dynamic> existing = const [],
  }) => source.toList();
  @override
  Future<LoadingState<List<dynamic>>> fetchRecommendations({
    required int index,
    required int pageSize,
    required CancelToken cancelToken,
  }) async {
    starts.add((index: index, milliseconds: now().inMilliseconds));
    await Future<void>.delayed(const Duration(seconds: 1));
    return Success(List.generate(10, (i) => index * 10 + i));
  }
}

void main() {
  setUpAll(() {
    GStorage.setting = MemoryBox<dynamic>();
    GStorage.localCache = MemoryBox<dynamic>();
  });

  testWidgets('容量使用实际布局尺寸，响应窗口与字体变化，并提供一行余量', (tester) async {
    late int target, columns;
    late double stride;
    Future<void> layout(Size size, {double fontScale = 1}) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            // 刻意提供大于列表的屏幕尺寸，容量仍应使用列表自身约束。
            data: MediaQueryData(
              size: const Size(3000, 2000),
              textScaler: TextScaler.linear(fontScale),
            ),
            child: Center(
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: RcmdViewport(
                  onChanged: (items, count, active) {
                    target = items;
                    columns = count;
                    expect(active, isTrue);
                  },
                  builder: (delegate, items, rowStride) {
                    stride = rowStride;
                    return const SizedBox.expand();
                  },
                ),
              ),
            ),
          ),
        ),
      );
      expect(columns, greaterThan(0));
      expect(target % columns, 0);
      final visibleRows = target ~/ columns - 1;
      expect(visibleRows * stride, greaterThanOrEqualTo(size.height));
      expect((visibleRows - 1) * stride, lessThan(size.height));
    }

    tester.view.physicalSize = const Size(3000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await layout(const Size(1896, 1000));
    final wideColumns = columns;
    final wideTarget = target;
    await layout(const Size(1896, 1080));
    expect(target, greaterThanOrEqualTo(wideTarget));
    await layout(const Size(366, 760));
    expect(columns, lessThan(wideColumns));
    final narrowColumns = columns;
    final narrowTarget = target;
    await layout(const Size(366, 760), fontScale: 2);
    expect(columns, narrowColumns);
    expect(target, lessThan(narrowTarget));
  });

  testWidgets('分页补足视口与一行预取，页脚不影响是否继续加载', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final origin = tester.binding.clock.now();
    final feed = _Recommendations(
      () => tester.binding.clock.now().difference(origin),
    );
    addTearDown(feed.onDelete.call);
    feed.onInit();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(1920, 1080)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: RcmdViewport(
              onChanged: (items, columns, active) => feed.updateViewport(
                itemCount: items,
                columns: columns,
                active: active,
              ),
              builder: (delegate, items, stride) => CustomScrollView(
                controller: feed.scrollController,
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.only(top: 8),
                    sliver: Obx(
                      () => SliverGrid.builder(
                        gridDelegate: delegate,
                        itemCount:
                            feed.loadingState.value.dataOrNull?.length ?? items,
                        itemBuilder: (_, _) => const SizedBox.expand(),
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 100)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    for (var second = 0; second < 10 && feed.isLoading; second++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final pages = (feed.viewportItems / 10).ceil();
    expect(feed.loadingState.value.data, hasLength(pages * 10));
    expect(
      feed.starts.map((request) => request.index),
      List.generate(pages, (i) => i),
    );
    expect(
      feed.starts.map((request) => request.milliseconds),
      List.generate(pages, (i) => i * 1000),
    );
    expect(feed.isLoading, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
