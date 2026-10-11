import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_paint_barrier.dart';

ui.FrameTiming timing(int frameNumber) => ui.FrameTiming(
  vsyncStart: 0,
  buildStart: 1,
  buildFinish: 2,
  rasterStart: 3,
  rasterFinish: 4,
  rasterFinishWallTime: 5,
  frameNumber: frameNumber,
);

void main() {
  testWidgets('UI frame completion cannot authorize native resize', (
    tester,
  ) async {
    final barrier = VideoOutputPaintBarrier(frameNumber: () => 40);
    addTearDown(barrier.dispose);
    var completed = false;
    final wait = barrier.wait().then((painted) {
      completed = true;
      return painted;
    });
    await tester.pump();
    expect(completed, isFalse, reason: 'endOfFrame is not a raster receipt');
    await tester.pump(const Duration(seconds: 2));
    expect(completed, isFalse, reason: 'Elapsed time cannot authorize resize');
    tester.platformDispatcher.onReportTimings?.call([timing(39)]);
    await tester.pump();
    expect(
      completed,
      isFalse,
      reason: 'An older queued scene is not protection',
    );
    tester.platformDispatcher.onReportTimings?.call([timing(40)]);
    await tester.pump();
    expect(await wait, isTrue);
  });

  testWidgets('a later raster receipt covers a dropped protected UI frame', (
    tester,
  ) async {
    final barrier = VideoOutputPaintBarrier(frameNumber: () => 40);
    addTearDown(barrier.dispose);
    final wait = barrier.wait();
    await tester.pump();
    tester.platformDispatcher.onReportTimings?.call([timing(41)]);
    await tester.pump();
    expect(await wait, isTrue);
  });

  testWidgets('missing frame identity refuses instead of guessing a delay', (
    tester,
  ) async {
    final barrier = VideoOutputPaintBarrier(frameNumber: () => -1);
    addTearDown(barrier.dispose);
    final wait = barrier.wait();
    await tester.pump();
    expect(await wait, isFalse);
  });

  testWidgets('source cancellation cannot authorize an old or a new resize', (
    tester,
  ) async {
    var frameNumber = 40;
    final barrier = VideoOutputPaintBarrier(frameNumber: () => frameNumber);
    addTearDown(barrier.dispose);
    final old = barrier.wait();
    await tester.pump();
    barrier.cancel();
    expect(await old, isFalse);
    frameNumber = 42;
    var completed = false;
    final next = barrier.wait().then((painted) {
      completed = true;
      return painted;
    });
    await tester.pump();
    tester.platformDispatcher.onReportTimings?.call([timing(40)]);
    await tester.pump();
    expect(completed, isFalse);
    tester.platformDispatcher.onReportTimings?.call([timing(42)]);
    await tester.pump();
    expect(await next, isTrue);
  });

  testWidgets('dispose unblocks waits without needing another UI frame', (
    tester,
  ) async {
    final barrier = VideoOutputPaintBarrier(frameNumber: () => 40);
    final wait = barrier.wait();
    barrier.dispose();
    expect(await wait, isFalse);
    expect(await barrier.wait(), isFalse);
    await tester.pump(); // The queued post-frame callback must be harmless.
    tester.platformDispatcher.onReportTimings?.call([timing(40)]);
    expect(tester.takeException(), isNull);
  });
}
