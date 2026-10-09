import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_handoff.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_paint_barrier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ui.Image fixture;
  setUp(() {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xFF42A5F5), ui.BlendMode.src);
    final picture = recorder.endRecording();
    fixture = picture.toImageSync(2, 2);
    picture.dispose();
  });
  tearDown(() => fixture.dispose());

  testWidgets(
    'bridge is painted before native resize and held until acquired frame',
    (tester) async {
      final events = <String>[];
      final consumed = Completer<bool>();
      late VideoOutputHandoff handoff;
      handoff = VideoOutputHandoff(
        waitForProtectedFrame: () async => true,
        capture: () async {
          events.add('capture');
          return fixture.clone();
        },
        waitForPaint: () async {
          events.add(handoff.image == null ? 'reveal' : 'bridge.paint');
        },
      );
      addTearDown(handoff.dispose);
      final run = handoff.run(
        isCurrent: () => true,
        canStart: () => true,
        submit: (_) {
          events.add('native');
          return consumed.future;
        },
      );
      await tester.pump();
      expect(events, ['capture', 'bridge.paint', 'native']);
      expect(handoff.image, isNotNull);
      await tester.pump(const Duration(seconds: 1));
      expect(
        handoff.image,
        isNotNull,
        reason: 'Elapsed time is not a frame-ready signal',
      );
      consumed.complete(true);
      expect(await run, isTrue);
      expect(handoff.image, isNull);
      expect(events, [
        'capture',
        'bridge.paint',
        'native',
        'bridge.paint',
        'reveal',
      ]);
    },
  );

  testWidgets('source changes during snapshot preparation cancel native work', (
    tester,
  ) async {
    final paint = Completer<void>();
    var current = true;
    var submissions = 0;
    final handoff = VideoOutputHandoff(
      waitForProtectedFrame: () async => true,
      capture: () async => fixture.clone(),
      waitForPaint: () => paint.future,
    );
    addTearDown(handoff.dispose);
    final run = handoff.run(
      isCurrent: () => current,
      canStart: () => true,
      submit: (_) async {
        submissions++;
        return true;
      },
    );
    await tester.pump();
    current = false;
    paint.complete();
    expect(await run, isFalse);
    expect(submissions, 0);
    expect(handoff.image, isNull);
  });

  testWidgets('pause or disabled setting before commit does not resize', (
    tester,
  ) async {
    var permitted = true;
    final paint = Completer<void>();
    var submissions = 0;
    final handoff = VideoOutputHandoff(
      waitForProtectedFrame: () async => true,
      capture: () async => fixture.clone(),
      waitForPaint: () => paint.future,
    );
    addTearDown(handoff.dispose);
    final run = handoff.run(
      isCurrent: () => true,
      canStart: () => permitted,
      submit: (_) async {
        submissions++;
        return true;
      },
    );
    await tester.pump();
    permitted = false;
    paint.complete();
    expect(await run, isFalse);
    expect(submissions, 0);
  });

  testWidgets(
    'source invalidation clears old snapshot and rejects late receipt',
    (tester) async {
      final frame = Completer<bool>();
      var current = true;
      final handoff = VideoOutputHandoff(
        waitForProtectedFrame: () async => true,
        capture: () async => fixture.clone(),
        waitForPaint: () async {},
      );
      addTearDown(handoff.dispose);
      final run = handoff.run(
        isCurrent: () => current,
        canStart: () => true,
        submit: (_) => frame.future,
      );
      await tester.pump();
      expect(handoff.image, isNotNull);
      current = false;
      handoff.invalidate();
      expect(handoff.image, isNull);
      frame.complete(true);
      expect(await run, isFalse);
    },
  );

  testWidgets(
    'missing snapshot refuses adaptive resize instead of exposing flash',
    (tester) async {
      var submissions = 0;
      final handoff = VideoOutputHandoff(
        waitForProtectedFrame: () async => true,
        capture: () async => null,
        waitForPaint: () async {},
      );
      addTearDown(handoff.dispose);
      expect(
        await handoff.run(
          isCurrent: () => true,
          canStart: () => true,
          submit: (_) async {
            submissions++;
            return true;
          },
        ),
        isFalse,
      );
      expect(submissions, 0);
    },
  );

  testWidgets(
    'native work waits for the protected Flutter frame raster receipt',
    (
      tester,
    ) async {
      final barrier = VideoOutputPaintBarrier(frameNumber: () => 40);
      addTearDown(barrier.dispose);
      var submissions = 0;
      final handoff = VideoOutputHandoff(
        capture: () async => fixture.clone(),
        waitForPaint: () async {},
        waitForProtectedFrame: barrier.wait,
      );
      addTearDown(handoff.dispose);
      final run = handoff.run(
        isCurrent: () => true,
        canStart: () => true,
        submit: (_) async {
          submissions++;
          return true;
        },
      );
      await tester.pump();
      await tester.pump();
      expect(handoff.image, isNotNull);
      expect(submissions, 0);
      tester.platformDispatcher.onReportTimings?.call([_timing(39)]);
      await tester.pump();
      expect(submissions, 0);
      tester.platformDispatcher.onReportTimings?.call([_timing(40)]);
      await tester.pump();
      expect(await run, isTrue);
      expect(submissions, 1);
      expect(handoff.image, isNull);
    },
  );

  testWidgets('unconfirmed protection refuses without native side effects', (
    tester,
  ) async {
    var submissions = 0;
    final handoff = VideoOutputHandoff(
      capture: () async => fixture.clone(),
      waitForPaint: () async {},
      waitForProtectedFrame: () async => false,
    );
    addTearDown(handoff.dispose);
    expect(
      await handoff.run(
        isCurrent: () => true,
        canStart: () => true,
        submit: (_) async {
          submissions++;
          return true;
        },
      ),
      isFalse,
    );
    expect(submissions, 0);
    expect(handoff.image, isNull);
  });

  testWidgets('source cancellation releases pending protected-frame work', (
    tester,
  ) async {
    final barrier = VideoOutputPaintBarrier(frameNumber: () => 40);
    addTearDown(barrier.dispose);
    var submissions = 0;
    final handoff = VideoOutputHandoff(
      capture: () async => fixture.clone(),
      waitForPaint: () async {},
      waitForProtectedFrame: barrier.wait,
    );
    addTearDown(handoff.dispose);
    final run = handoff.run(
      isCurrent: () => true,
      canStart: () => true,
      submit: (_) async {
        submissions++;
        return true;
      },
    );
    await tester.pump();
    await tester.pump();
    handoff.invalidate();
    barrier.cancel();
    expect(await run, isFalse);
    expect(submissions, 0);
    expect(handoff.image, isNull);
  });

  testWidgets(
    'pause after commit retains protection until frame receipt',
    (
      tester,
    ) async {
      final frame = Completer<bool>();
      var playing = true;
      final handoff = VideoOutputHandoff(
        capture: () async => fixture.clone(),
        waitForPaint: () async {},
        waitForProtectedFrame: () async => true,
      );
      addTearDown(handoff.dispose);
      final run = handoff.run(
        isCurrent: () => true,
        canStart: () => playing,
        submit: (_) => frame.future,
      );
      await tester.pump();
      playing = false;
      await tester.pump(const Duration(seconds: 2));
      expect(handoff.image, isNotNull);
      // Resume produces the receipt; paused frames retain the protective image.
      playing = true;
      frame.complete(true);
      expect(await run, isTrue);
      expect(handoff.image, isNull);
    },
  );

  testWidgets('native failure cannot remove the protective bridge', (
    tester,
  ) async {
    final handoff = VideoOutputHandoff(
      waitForProtectedFrame: () async => true,
      capture: () async => fixture.clone(),
      waitForPaint: () async {},
    );
    addTearDown(handoff.dispose);
    await expectLater(
      handoff.run(
        isCurrent: () => true,
        canStart: () => true,
        submit: (_) => Future<bool>.error(StateError('partial native failure')),
      ),
      throwsStateError,
    );
    expect(handoff.image, isNotNull);
    handoff.invalidate();
    expect(handoff.image, isNull);
  });
  testWidgets('partial failure restores old geometry before releasing bridge', (
    tester,
  ) async {
    final restored = Completer<bool>();
    var restoring = false;
    final handoff = VideoOutputHandoff(
      waitForProtectedFrame: () async => true,
      capture: () async => fixture.clone(),
      waitForPaint: () async {},
    );
    addTearDown(handoff.dispose);
    final run = handoff.run(
      isCurrent: () => true,
      canStart: () => true,
      submit: (_) => Future<bool>.error(StateError('partial commit')),
      recover: () {
        restoring = true;
        return restored.future;
      },
    );
    await tester.pump();
    expect(restoring, isTrue);
    expect(handoff.image, isNotNull);
    final verdict = expectLater(run, throwsStateError);
    restored.complete(true);
    await verdict;
    expect(handoff.image, isNull);
  });
}

ui.FrameTiming _timing(int frameNumber) => ui.FrameTiming(
  vsyncStart: 0,
  buildStart: 1,
  buildFinish: 2,
  rasterStart: 3,
  rasterFinish: 4,
  rasterFinishWallTime: 5,
  frameNumber: frameNumber,
);
