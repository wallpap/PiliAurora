import 'dart:math' as math;

import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final hz in [60, 90, 120, 144]) {
    for (final fps in [60, 90, 120]) {
      for (final workMicros in [0, 2000]) {
        testWidgets('$hz Hz / $fps FPS：更新耗时 $workMicros us，夹杂高频 UI 帧', (
          tester,
        ) async {
          tester.view.display.refreshRate = hz.toDouble();
          addTearDown(tester.view.display.resetRefreshRate);
          final origin = tester.binding.clock.now().microsecondsSinceEpoch;
          int now() => tester.binding.clock.now().microsecondsSinceEpoch;
          final ticks = <int>[];
          final ticker = _ClockTicker(
            (elapsed) {
              ticks.add(elapsed.inMicroseconds);
              (tester.binding as AutomatedTestWidgetsFlutterBinding)
                  .elapseBlocking(Duration(microseconds: workMicros));
            },
            now,
            fps,
          )..start();
          addTearDown(ticker.dispose);
          await tester.pump();
          final slotMicros = (1000000 / hz).ceil();
          for (var slot = 1; slot <= hz * 4; slot++) {
            await tester.binding.delayed(
              Duration(microseconds: origin + slot * slotMicros - now()),
            );
            if (slot > hz && slot <= hz * 2) {
              tester.binding.scheduleFrame();
            }
            if (tester.binding.hasScheduledFrame) await tester.pump();
          }
          final effectiveRate = math.min(hz, fps);
          expect(ticks.length - 1, closeTo(effectiveRate * 4, 1));
          final maxInterval = (hz / effectiveRate).ceil() * slotMicros;
          expect(ticks.last, greaterThanOrEqualTo(4000000 - maxInterval));
          for (var i = 1; i < ticks.length; i++) {
            expect(ticks[i] - ticks[i - 1], lessThanOrEqualTo(maxInterval));
          }
          ticker.stop();
          final stoppedTicks = ticks.length;
          await tester.pump();
          await tester.binding.delayed(const Duration(seconds: 1));
          expect(ticks.length, stoppedTicks);
          expect(tester.binding.hasScheduledFrame, isFalse);
        });
      }
    }
  }
}

class _ClockTicker extends FrameRateTicker {
  _ClockTicker(super.onTick, this.now, int fps) : super(frameRate: fps);

  final int Function() now;

  @override
  int get clockMicroseconds => now();
}
