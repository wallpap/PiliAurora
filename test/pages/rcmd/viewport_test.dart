import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/rcmd/controller.dart';
import 'package:pili_aurora/pages/rcmd/viewport.dart';
import 'package:pili_aurora/utils/storage.dart';

class _Settings implements Box<dynamic> {
  @override
  dynamic get(dynamic key, {dynamic defaultValue}) => defaultValue;
  @override
  Future<void> put(dynamic key, dynamic value) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
    GStorage.setting = _Settings();
    GStorage.localCache = _Settings();
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
    }

    tester.view.physicalSize = const Size(3000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await layout(const Size(1896, 1000));
    expect(columns, 8);
    expect(target, 48);
    expect((target ~/ columns - 1) * stride, greaterThanOrEqualTo(1000));
    await layout(const Size(1896, 1080));
    expect(target, 48);
    await layout(const Size(366, 760));
    expect(columns, 2);
    expect(target, 10);
    await layout(const Size(366, 760), fontScale: 2);
    expect(columns, 2);
    expect(target, 8);
  });

  for (final height in [1000.0, 1080.0]) {
    testWidgets('1920×$height 补足视口与一行预取，100px页脚不会提前结束', (tester) async {
      tester.view.physicalSize = Size(1920, height);
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
            data: MediaQueryData(size: Size(1920, height)),
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
                              feed.loadingState.value.dataOrNull?.length ??
                              items,
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
      for (var second = 0; second < 5; second++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(feed.viewportItems, 48);
      expect(feed.loadingState.value.data, hasLength(50));
      expect(feed.starts.map((request) => request.index), [0, 1, 2, 3, 4]);
      expect(feed.starts.map((request) => request.milliseconds), [
        0,
        1000,
        2000,
        3000,
        4000,
      ]);
      expect(feed.isLoading, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
