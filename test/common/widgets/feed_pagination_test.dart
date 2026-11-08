import 'dart:async';

import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/common/widgets/feed_pagination.dart';
import 'package:pili_aurora/utils/grid.dart' as grid;
import 'package:waterfall_flow/waterfall_flow.dart';

class _Feed extends StatefulWidget {
  const _Feed({
    this.count = 20,
    this.allowed = true,
    this.cacheExtent = 250,
    this.waterfall = false,
    this.prefetchExtent,
  });
  final int count;
  final bool allowed;
  final double cacheExtent;
  final bool waterfall;
  final double? prefetchExtent;

  @override
  State<_Feed> createState() => _FeedState();
}

class _FeedState extends State<_Feed> {
  final controller = ScrollController();
  final changes = StreamController<Object?>.broadcast(sync: true);
  late int count = widget.count;
  late bool allowed = widget.allowed;
  int requests = 0;
  Completer<void>? pending;
  bool grow = true;

  void replace(int value) {
    setState(() => count = value);
    changes.add(value);
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: FeedPagination(
      prefetchExtent: widget.prefetchExtent == null
          ? null
          : () => widget.prefetchExtent!,
      controller: controller,
      dataChanges: changes.stream,
      canLoadMore: () => allowed,
      onLoadMore: () async {
        requests++;
        if (pending != null) await pending!.future;
        if (mounted && grow) replace(count + 20);
      },
      child: CustomScrollView(
        controller: controller,
        scrollCacheExtent: ScrollCacheExtent.pixels(widget.cacheExtent),
        slivers: [
          if (widget.waterfall)
            SliverWaterfallFlow(
              gridDelegate:
                  const SliverWaterfallFlowDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                  ),
              delegate: SliverChildBuilderDelegate(
                (_, index) => SizedBox(height: 100.0 + index % 3 * 10),
                childCount: count,
              ),
            )
          else
            SliverGrid.builder(
              gridDelegate: grid.SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 480,
                mainAxisExtent: 110,
                mainAxisSpacing: 2,
              ),
              itemCount: count,
              itemBuilder: (_, index) {
                return const SizedBox.expand();
              },
            ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    changes.close();
    controller.dispose();
    super.dispose();
  }
}

void main() {
  testWidgets('通知模式沿用嵌套滚动控制器，按真实范围分页', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var calls = 0;
    var allowed = false;
    Widget feed(int revision) => Directionality(
      textDirection: TextDirection.ltr,
      child: PrimaryScrollController(
        controller: controller,
        child: FeedPagination.notifications(
          dataRevision: revision,
          canLoadMore: () => allowed,
          onLoadMore: () async {
            calls++;
            allowed = false;
          },
          child: ListView(
            primary: true,
            children: const [SizedBox(height: 1500)],
          ),
        ),
      ),
    );
    await tester.pumpWidget(feed(0));
    await tester.pumpAndSettle();
    allowed = true;
    await tester.pumpWidget(feed(1));
    await tester.pumpAndSettle();
    expect(calls, 0);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('快照修订在滚动范围未变化时重新检查，不需要 stream 桥接', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var allowed = false;
    var requests = 0;
    Widget feed(int revision) => Directionality(
      textDirection: TextDirection.ltr,
      child: FeedPagination(
        controller: controller,
        dataRevision: revision,
        canLoadMore: () => allowed,
        onLoadMore: () async {
          requests++;
          allowed = false;
        },
        child: ListView(controller: controller),
      ),
    );
    await tester.pumpWidget(feed(0));
    await tester.pumpAndSettle();
    expect(requests, 0);
    allowed = true;
    await tester.pumpWidget(feed(1));
    await tester.pumpAndSettle();
    expect(requests, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('更换快照所有者后同一滚动控制器不等待旧请求', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final oldSource = Object(), newSource = Object();
    final oldRequest = Completer<void>(), newRequest = Completer<void>();
    var calls = 0;
    Widget feed(Object source) => Directionality(
      textDirection: TextDirection.ltr,
      child: FeedPagination(
        controller: controller,
        dataSource: source,
        canLoadMore: () => true,
        onLoadMore: () {
          calls++;
          return identical(source, oldSource)
              ? oldRequest.future
              : newRequest.future;
        },
        child: ListView(controller: controller),
      ),
    );
    await tester.pumpWidget(feed(oldSource));
    await tester.pumpAndSettle();
    expect(calls, 1);
    await tester.pumpWidget(feed(newSource));
    await tester.pumpAndSettle();
    expect(calls, 2);
    oldRequest.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(feed(newSource));
    await tester.pumpAndSettle();
    expect(calls, 2);
    newRequest.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  Future<_FeedState> mount(
    WidgetTester tester, {
    _Feed feed = const _Feed(),
  }) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(feed);
    await tester.pumpAndSettle();
    return tester.state<_FeedState>(find.byType(_Feed));
  }

  testWidgets('fills the viewport without loading a third page for the cache', (
    tester,
  ) async {
    final feed = await mount(tester);
    expect(feed.count, 40);
    expect(feed.requests, 1);
    await tester.pumpAndSettle();
    expect(feed.requests, 1);
    feed.controller.jumpTo(feed.controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(feed.count, 60);
    expect(feed.requests, 2);
  });

  testWidgets('home prefetches with two grid rows remaining', (
    tester,
  ) async {
    final feed = await mount(
      tester,
      feed: const _Feed(count: 160, prefetchExtent: 224),
    );
    expect(feed.requests, 0);
    feed.pending = Completer<void>();
    final position = feed.controller.position;
    feed.controller.jumpTo(
      position.maxScrollExtent - 225,
    );
    await tester.pumpAndSettle();
    expect(feed.requests, 0);
    feed.controller.jumpTo(
      position.maxScrollExtent - 223,
    );
    await tester.pumpAndSettle();
    expect(feed.requests, 1);
    feed.pending!.complete();
    await tester.pumpAndSettle();
    expect(feed.requests, 1);
    expect(feed.count, 180);
  });

  testWidgets(
    'data arrival fills a short list even when scroll extent stays zero',
    (tester) async {
      final feed = await mount(
        tester,
        feed: const _Feed(count: 0, allowed: false),
      );
      feed
        ..allowed = true
        ..replace(4);
      await tester.pumpAndSettle();
      expect(feed.count, 44);
      expect(feed.requests, 2);
    },
  );

  testWidgets(
    'in-flight requests are serialized and no-growth responses stop',
    (tester) async {
      final feed = await mount(tester, feed: const _Feed(count: 40));
      feed
        ..pending = Completer<void>()
        ..grow = false;
      feed.controller.jumpTo(feed.controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      feed.changes.add(null);
      await tester.pump();
      expect(feed.requests, 1);
      feed.pending!.complete();
      await tester.pumpAndSettle();
      expect(feed.requests, 1);
      feed.allowed = false;
      feed.changes.add(null);
      await tester.pump();
      expect(feed.requests, 1);
    },
  );

  testWidgets('同一列表重建时 Rx.stream 新包装不解除在途请求的串行约束', (tester) async {
    final controller = ScrollController();
    final data = 0.obs;
    final pending = Completer<void>();
    var requests = 0;
    addTearDown(controller.dispose);
    addTearDown(data.close);
    Widget feed() => Directionality(
      textDirection: TextDirection.ltr,
      child: FeedPagination(
        controller: controller,
        dataChanges: data.stream,
        canLoadMore: () => true,
        onLoadMore: () {
          requests++;
          return pending.future;
        },
        child: ListView(controller: controller),
      ),
    );
    await tester.pumpWidget(feed());
    await tester.pumpAndSettle();
    expect(requests, 1);
    await tester.pumpWidget(feed());
    data.value++;
    await tester.pumpAndSettle();
    expect(requests, 1);
    pending.complete();
    await tester.pumpAndSettle();
    expect(requests, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('替换来源立即检查新列表，旧请求完成不释放新来源的加载标记', (tester) async {
    final oldController = ScrollController();
    final newController = ScrollController();
    final oldChanges = StreamController<Object?>.broadcast(sync: true);
    final newChanges = StreamController<Object?>.broadcast(sync: true);
    final oldRequest = Completer<void>();
    final newRequest = Completer<void>();
    addTearDown(oldController.dispose);
    addTearDown(newController.dispose);
    addTearDown(oldChanges.close);
    addTearDown(newChanges.close);
    var oldCalls = 0, newCalls = 0;
    Widget feed(bool current) => Directionality(
      textDirection: TextDirection.ltr,
      child: FeedPagination(
        controller: current ? newController : oldController,
        dataChanges: current ? newChanges.stream : oldChanges.stream,
        canLoadMore: () => true,
        onLoadMore: () {
          if (current) {
            newCalls++;
            return newRequest.future;
          }
          oldCalls++;
          return oldRequest.future;
        },
        child: ListView(controller: current ? newController : oldController),
      ),
    );
    await tester.pumpWidget(feed(false));
    await tester.pumpAndSettle();
    expect(oldCalls, 1);
    await tester.pumpWidget(feed(true));
    await tester.pumpAndSettle();
    expect(newCalls, 1);
    oldRequest.complete();
    await tester.pump();
    newChanges.add(null);
    await tester.pump();
    expect(newCalls, 1);
    newRequest.complete();
    await tester.pumpAndSettle();
    expect(newCalls, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'pending pagination is cancelled by unmount and disabled ticker',
    (tester) async {
      final feed = await mount(tester, feed: const _Feed(count: 40));
      feed.controller.jumpTo(feed.controller.position.maxScrollExtent);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(feed.requests, 0);
      await tester.pumpWidget(const TickerMode(enabled: false, child: _Feed()));
      await tester.pumpAndSettle();
      expect(tester.state<_FeedState>(find.byType(_Feed)).requests, 0);
      await tester.pumpWidget(const TickerMode(enabled: true, child: _Feed()));
      await tester.pumpAndSettle();
      expect(tester.state<_FeedState>(find.byType(_Feed)).requests, 1);
    },
  );

  testWidgets(
    'waterfall layout paginates after scrolling near its actual end',
    (tester) async {
      final feed = await mount(
        tester,
        feed: const _Feed(count: 40, waterfall: true, cacheExtent: 0),
      );
      expect(feed.requests, 0);
      feed.controller.jumpTo(feed.controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(feed.requests, 1);
      expect(feed.count, 60);
    },
  );
}
