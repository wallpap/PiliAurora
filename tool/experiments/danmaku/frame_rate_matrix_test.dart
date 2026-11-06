import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../test/pages/danmaku/frame_sync_fixture.dart';

void main() {
  const synchronizedPairs = {
    (24, 120),
    (30, 60),
    (30, 90),
    (30, 120),
    (60, 60),
    (60, 120),
  };
  for (final refreshRate in [60, 90, 120, 144]) {
    for (final displaySyncActive in [false, true]) {
      for (final videoRate in [24, 30, 60]) {
        for (final danmakuRate in [60, 90, 120]) {
          testWidgets('$refreshRate Hz：视频 $videoRate FPS / 弹幕 $danmakuRate FPS，'
              '显示同步=$displaySyncActive', (
            tester,
          ) async {
            tester.view.display.refreshRate = refreshRate.toDouble();
            addTearDown(tester.view.display.resetRefreshRate);
            final frames = ValueNotifier<List<int>>(const []);
            final syncActive = ValueNotifier<bool>(displaySyncActive);
            addTearDown(frames.dispose);
            addTearDown(syncActive.dispose);
            final fixture = FrameSyncFixture(
              tester,
              refreshRate.toDouble(),
              roundSlotsUp: true,
            );
            var ticks = 0;
            final ticker = _ClockTicker(
              (_) => ticks++,
              () => fixture.now,
              danmakuRate,
              frames,
              syncActive,
            )..start();
            await tester.pump();
            final initialTicks = ticks;
            final available = <int>[];
            var alignedSlots = 0;
            var shiftedSlots = 0;
            var alignedTicks = 0;
            var shiftedTicks = 0;
            var videoFrames = 0;
            final slotMicros = (1000000 / refreshRate).ceil();
            final videoPeriod = 1000000 / videoRate;
            var nextVideo = videoPeriod;
            for (var slot = 1; slot <= refreshRate * 6; slot++) {
              await tester.binding.delayed(Duration(microseconds: slotMicros));
              // 用媒体周期映射屏幕槽位，覆盖 24 FPS 在 60 Hz、30 FPS 在
              // 144 Hz 等非整数比例。三秒后将视频时序延后一个槽位。
              if (slot == refreshRate * 3 + 1) nextVideo += slotMicros;
              final hasVideo = slot * slotMicros >= nextVideo;
              if (hasVideo) {
                nextVideo += videoPeriod;
                videoFrames++;
                available.add(fixture.requestForSlot(slot));
              }
              final previousTicks = ticks;
              final hasDart = await fixture.pump(hasVideo: hasVideo);
              if (slot % (refreshRate / 4).round() == 0) {
                frames.value = available.toList();
                available.clear();
              }
              if (slot > refreshRate && slot <= refreshRate * 3) {
                alignedTicks += ticks - previousTicks;
              }
              if (slot > refreshRate * 4) shiftedTicks += ticks - previousTicks;
              if (hasVideo || hasDart) {
                if (slot > refreshRate && slot <= refreshRate * 3) {
                  alignedSlots++;
                }
                if (slot > refreshRate * 4) shiftedSlots++;
              }
            }
            ticker.dispose();
            final disposedTicks = ticks;
            await tester.pump();
            await tester.binding.delayed(const Duration(seconds: 2));
            expect(tester.binding.hasScheduledFrame, isFalse);
            expect(ticks, disposedTicks);
            debugPrint(
              'matrix screen=$refreshRate video=$videoRate danmaku=$danmakuRate '
              'displaySync=$displaySyncActive '
              'updates=${ticks - initialTicks}/6s '
              'updates-before=$alignedTicks/2s updates-after=$shiftedTicks/2s '
              'combined-before=$alignedSlots/2s combined-after=$shiftedSlots/2s',
            );
            final effectiveRate = danmakuRate < refreshRate
                ? danmakuRate
                : refreshRate;
            expect(videoFrames, closeTo(videoRate * 6, 1));
            expect(ticks - initialTicks, closeTo(effectiveRate * 6, 3));
            expect(alignedTicks, closeTo(effectiveRate * 2, 2));
            expect(shiftedTicks, closeTo(effectiveRate * 2, 2));
            // 视频周期能稳定映射到屏幕槽位时验证合帧；其余组合验证
            // 退化后仍保持目标更新频率，允许视频独立刷新。
            if (refreshRate % videoRate == 0 &&
                synchronizedPairs.contains((videoRate, danmakuRate))) {
              final combinedRate = videoRate > effectiveRate
                  ? videoRate
                  : effectiveRate;
              expect(alignedSlots, closeTo(combinedRate * 2, 2));
              expect(shiftedSlots, closeTo(combinedRate * 2, 2));
            }
          });
        }
      }
    }
  }
}

class _ClockTicker extends FrameRateTicker {
  _ClockTicker(
    super.onTick,
    this.now,
    int rate,
    ValueListenable<List<int>> frames,
    ValueListenable<bool> syncActive,
  ) : super(
        frameRate: rate,
        videoFrameTimings: frames,
        videoDisplaySyncActive: syncActive,
      );

  final int Function() now;

  @override
  int get clockMicroseconds => now();
}
