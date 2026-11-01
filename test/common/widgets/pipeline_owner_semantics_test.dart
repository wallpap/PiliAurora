import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class _Manifold extends ChangeNotifier implements PipelineManifold {
  @override
  bool get semanticsEnabled => true;

  @override
  void requestVisualUpdate() {}
}

class _Gate extends RenderProxyBox {
  _Gate(this._active, [RenderBox? child]) : super(child);

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

RenderSemanticsAnnotations _card(String label) => RenderSemanticsAnnotations(
  container: true,
  properties: SemanticsProperties(label: label, button: true),
  textDirection: TextDirection.ltr,
  child: RenderConstrainedBox(
    additionalConstraints: const BoxConstraints.tightFor(
      width: 100,
      height: 20,
    ),
  ),
);

RenderSemanticsAnnotations _root(RenderBox child) => RenderSemanticsAnnotations(
  container: true,
  explicitChildNodes: true,
  properties: const SemanticsProperties(),
  textDirection: TextDirection.ltr,
  child: child,
);

void _disposeTree(RenderObject object) {
  object
    ..visitChildren(_disposeTree)
    ..dispose();
}

WeakReference<RenderObject> _removeOldCard(RenderFlex column) {
  final card = column.firstChild!;
  column.remove(card);
  final reference = WeakReference<RenderObject>(card);
  _disposeTree(card);
  return reference;
}

bool _isDisposed(WeakReference<RenderObject> reference) =>
    reference.target?.debugDisposed ?? true;

bool _isAlive(WeakReference<RenderObject> reference) =>
    reference.target != null;

Future<void> _forceGC() async {
  final barrier = developer.reachabilityBarrier;
  final watch = Stopwatch()..start();
  final allocations = <List<int>>[];
  while (developer.reachabilityBarrier < barrier + 2) {
    if (watch.elapsed > const Duration(seconds: 10)) {
      throw StateError('GC barrier did not advance');
    }
    await Future<void>.delayed(Duration.zero);
    allocations.add(List.generate(30000, (index) => index));
    if (allocations.length > 100) allocations.removeAt(0);
  }
}

void main() {
  for (final (migrate, flushOldLayout) in [
    (false, true),
    (true, false),
    (true, true),
  ]) {
    testWidgets(
      'blocked branch releases disposed cards: migrate=$migrate oldLayout=$flushOldLayout',
      (tester) async {
        final column = RenderFlex(direction: Axis.vertical)
          ..addAll([_card('old'), _card('remaining')]);
        final gateA = _Gate(true, column);
        final gateB = _Gate(false);
        final rootA = _root(gateA);
        final rootB = _root(gateB);
        late final PipelineOwner ownerA;
        late final PipelineOwner ownerB;
        ownerA = PipelineOwner(
          onSemanticsUpdate: (ui.SemanticsUpdate update) => update.dispose(),
          onSemanticsOwnerCreated: rootA.scheduleInitialSemantics,
        )..rootNode = rootA;
        ownerB = PipelineOwner(
          onSemanticsUpdate: (ui.SemanticsUpdate update) => update.dispose(),
          onSemanticsOwnerCreated: rootB.scheduleInitialSemantics,
        )..rootNode = rootB;
        final manifold = _Manifold();
        ownerA.attach(manifold);
        ownerB.attach(manifold);
        late final bool aliveWhileHidden;
        try {
          const constraints = BoxConstraints.tightFor(width: 100, height: 100);
          rootA.layout(constraints);
          rootB.layout(constraints);
          ownerA.flushSemantics();
          ownerB.flushSemantics();
          expect(rootA.debugSemantics!.toStringDeep(), contains('old'));

          final removed = _removeOldCard(column);
          expect(_isDisposed(removed), isTrue);
          // 已在 A 完成布局，语义阶段尚未开始；迁移时相同 constraints 无需重排 C。
          if (flushOldLayout) ownerA.flushLayout();
          if (migrate) {
            // C 的语义已 dirty 且只在 A 排队；尚未 flush 就移到 B 的隐藏分支。
            gateA.child = null;
            gateB.child = column;
            expect(column.owner, same(ownerB));
          } else {
            gateA.active = false;
          }
          ownerA.flushLayout();
          ownerB.flushLayout();
          ownerA.flushSemantics();
          ownerB.flushSemantics();
          await tester.runAsync(_forceGC);
          aliveWhileHidden = _isAlive(removed);

          if (migrate) {
            gateB.active = true;
            ownerB.flushSemantics();
            expect(rootB.debugSemantics!.toStringDeep(), contains('remaining'));
          } else {
            gateA.active = true;
            ownerA.flushSemantics();
            expect(rootA.debugSemantics!.toStringDeep(), contains('remaining'));
          }
          await tester.runAsync(_forceGC);
          expect(_isAlive(removed), isFalse);
        } finally {
          ownerA.rootNode = null;
          ownerB.rootNode = null;
          ownerA.detach();
          ownerB.detach();
          _disposeTree(rootA);
          _disposeTree(rootB);
          ownerA.dispose();
          ownerB.dispose();
          manifold.dispose();
        }
        expect(
          aliveWhileHidden,
          isFalse,
          reason: 'a migrated blocked branch must release its disposed card',
        );
      },
    );
  }
}
