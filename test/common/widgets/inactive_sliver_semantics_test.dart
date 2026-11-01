import 'dart:developer' as developer;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/inactive_feed_sliver.dart';

// 同时覆盖直接隐藏和语义访问被祖先截断的分支。
// 外层由真实 InactiveFeedSliver 执行标准列表回收。
class _SliverSemanticsGate extends SingleChildRenderObjectWidget {
  const _SliverSemanticsGate({required this.active, required super.child});

  final bool active;

  @override
  _RenderSliverSemanticsGate createRenderObject(BuildContext context) =>
      _RenderSliverSemanticsGate(active);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSliverSemanticsGate renderObject,
  ) {
    renderObject.active = active;
  }
}

class _RenderSliverSemanticsGate extends RenderProxySliver {
  _RenderSliverSemanticsGate(this._active);

  bool _active;

  set active(bool value) {
    if (_active == value) return;
    _active = value;
    markNeedsSemanticsUpdate();
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_active) super.visitChildrenForSemantics(visitor);
  }
}

typedef _WeakCard = ({int index, WeakReference<_RenderCardProbe> reference});

class _CardTracker {
  final created = <_WeakCard>[];
}

class _CardProbe extends SingleChildRenderObjectWidget {
  const _CardProbe({
    required this.index,
    required this.tracker,
    required super.child,
  });

  final int index;
  final _CardTracker tracker;

  @override
  _RenderCardProbe createRenderObject(BuildContext context) {
    final renderObject = _RenderCardProbe();
    tracker.created.add((index: index, reference: WeakReference(renderObject)));
    return renderObject;
  }
}

class _RenderCardProbe extends RenderProxyBox {}

class _ProbePage extends StatefulWidget {
  const _ProbePage({super.key, required this.gate, required this.tracker});

  final bool gate;
  final _CardTracker tracker;

  @override
  State<_ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<_ProbePage> {
  final controller = ScrollController(initialScrollOffset: 250);
  final focusNode = FocusNode();
  final loadedData = List.generate(100, (index) => index);

  @override
  void dispose() {
    controller.dispose();
    focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focusNode,
    child: ScrollConfiguration(
      behavior: const ScrollBehavior().copyWith(scrollbars: false),
      child: CustomScrollView(
        controller: controller,
        slivers: [
          _SliverSemanticsGate(
            active: !widget.gate || TickerMode.valuesOf(context).enabled,
            child: InactiveFeedSliver(
              sliver: SliverList.builder(
                itemCount: loadedData.length,
                itemBuilder: (_, index) => SizedBox(
                  height: 100,
                  child: _CardProbe(
                    index: loadedData[index],
                    tracker: widget.tracker,
                    child: Semantics(
                      label: 'card $index',
                      button: true,
                      child: Text('title $index'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

// 与 leak_tracker 的 forceGC 原理一致，不引入额外测试依赖。
// barrier 跨越后，之前不可达的对象必已回收；不会把“语义不可见”当回收。
Future<void> _crossReachabilityBarriers() async {
  final barrier = developer.reachabilityBarrier;
  final stopwatch = Stopwatch()..start();
  final storage = <List<int>>[];
  while (developer.reachabilityBarrier < barrier + 2) {
    if (stopwatch.elapsed > const Duration(seconds: 10)) {
      throw StateError('GC reachability barrier did not advance');
    }
    await Future<void>.delayed(Duration.zero);
    storage.add(List.generate(30000, (index) => index));
    if (storage.length > 100) storage.removeAt(0);
  }
}

// 隐藏时可能已发生GC，不能把更早回收的卡片排除在退出数量之外。
List<_WeakCard> _disposedCards(List<_WeakCard> references) => references
    .where((entry) => entry.reference.target?.debugDisposed ?? true)
    .toList();

int _survivingCount(List<_WeakCard> references) =>
    references.where((entry) => entry.reference.target != null).length;

List<int> _survivingIndices(List<_WeakCard> references) => references
    .where((entry) => entry.reference.target != null)
    .map((entry) => entry.index)
    .toList();

int _liveCardCount(_CardTracker tracker) => tracker.created
    .where((entry) => entry.reference.target?.debugDisposed == false)
    .length;

void main() {
  for (final (semanticsEnabled, gate, ancestorOffstage) in [
    (false, false, false),
    (true, false, false),
    (true, true, false),
    (false, false, true),
    (true, false, true),
    (true, true, true),
  ]) {
    testWidgets(
      'disposed cards: semantics=$semanticsEnabled gate=$gate offstage=$ancestorOffstage',
      (tester) async {
        final semantics = semanticsEnabled ? tester.ensureSemantics() : null;
        try {
          expect(tester.binding.semanticsEnabled, semanticsEnabled);
          final pageKey = GlobalKey<_ProbePageState>();
          final tracker = _CardTracker();
          Widget scene(bool active) => Directionality(
            textDirection: TextDirection.ltr,
            child: TickerMode(
              enabled: active,
              child: Offstage(
                offstage: ancestorOffstage && !active,
                child: _ProbePage(
                  key: pageKey,
                  gate: gate,
                  tracker: tracker,
                ),
              ),
            ),
          );

          await tester.pumpWidget(scene(true));
          await tester.pumpAndSettle();
          final page = pageKey.currentState!;
          final position = page.controller.position;
          final data = page.loadedData;
          final initialCardReferences = tracker.created
              .where((entry) => entry.reference.target?.debugDisposed == false)
              .toList();
          final initialCards = initialCardReferences.length;
          expect(initialCards, greaterThan(1));
          if (semanticsEnabled) {
            expect(find.bySemanticsLabel(RegExp('card 3')), findsWidgets);
          }

          await tester.pumpWidget(scene(false));
          await tester.pumpAndSettle();
          expect(_liveCardCount(tracker), 1);
          final disposedCards = _disposedCards(initialCardReferences);
          expect(disposedCards, hasLength(initialCards - 1));
          if (semanticsEnabled) {
            expect(find.bySemanticsLabel(RegExp('card 3')), findsNothing);
          }
          await tester.runAsync(_crossReachabilityBarriers);
          final retainedWhileHidden = _survivingCount(disposedCards);
          final retainedIndices = _survivingIndices(disposedCards);

          await tester.pumpWidget(scene(true));
          await tester.pumpAndSettle();
          expect(pageKey.currentState, same(page));
          expect(page.controller.position, same(position));
          expect(page.loadedData, same(data));
          expect(position.pixels, 250);
          page.focusNode.requestFocus();
          await tester.pumpAndSettle();
          expect(page.focusNode.hasPrimaryFocus, isTrue);
          if (semanticsEnabled) {
            expect(find.bySemanticsLabel(RegExp('card 3')), findsWidgets);
          }
          await tester.runAsync(_crossReachabilityBarriers);
          final retainedAfterRestore = _survivingCount(disposedCards);

          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await tester.runAsync(_crossReachabilityBarriers);
          debugPrint(
            'semantics=$semanticsEnabled gate=$gate offstage=$ancestorOffstage: '
            'cards=$initialCards -> 1; disposed=${disposedCards.length}; '
            'still reachable hidden=$retainedWhileHidden $retainedIndices; '
            'restored=$retainedAfterRestore; '
            'unmounted=${_survivingCount(disposedCards)}',
          );
          expect(_survivingCount(disposedCards), 0);
          expect(retainedAfterRestore, 0);
          expect(
            retainedWhileHidden,
            0,
            reason: 'disposed cards must not remain reachable while hidden',
          );
        } finally {
          semantics?.dispose();
        }
      },
      // 由本测试显式持有语义句柄，保留真正关闭语义的单变量对照。
      semanticsEnabled: false,
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}
