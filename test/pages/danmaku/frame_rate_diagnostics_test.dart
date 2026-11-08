import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'frame_sync_fixture.dart';

void main() {
  testWidgets('诊断区分提前回调与长更新间隔，并排除暂停空档', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final fixture = FrameSyncFixture(tester, 120);
    final ticker = _ClockTicker((_) {}, fixture)..start();
    await tester.pump();
    // 第1槽为提前到达的外部帧；第6槽缺失，制造一次33ms更新间隔。
    for (final slot in [1, 2, 4, 8, 10]) {
      await fixture.elapseToSlot(slot);
      tester.binding.scheduleFrame();
      await tester.pump();
    }
    final stats = ticker.diagnostics;
    expect(stats['frameCallbacks'], 6);
    expect(stats['updates'], 5);
    expect(stats['deadlineSkips'], 1);
    expect(stats['longUpdateGaps'], 1);
    expect(stats['maxUpdateGapUs'], inInclusiveRange(33333, 33334));
    expect(stats['updateGapBuckets'], {
      'le10000': 0,
      'le20000': 3,
      'le30000': 0,
      'le40000': 1,
      'le60000': 0,
      'le100000': 0,
      'gt100000': 0,
    });
    ticker.muted = true;
    await tester.binding.delayed(const Duration(seconds: 1));
    ticker.muted = false;
    await tester.pump();
    expect(ticker.diagnostics['updateGapBuckets'], stats['updateGapBuckets']);
    expect(ticker.diagnostics['longUpdateGaps'], 1);
    ticker.dispose();
  });

  for (final target in [0, 60, 90, 120]) {
    testWidgets('$target FPS 正常槽位量化不计为长更新间隔', (tester) async {
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      final fixture = FrameSyncFixture(tester, 120);
      final ticker = _ClockTicker((_) {}, fixture, frameRate: target)..start();
      await tester.pump();
      for (var slot = 1; slot <= 240; slot++) {
        await fixture.elapseToSlot(slot);
        await fixture.pump(hasVideo: false);
      }
      expect(ticker.diagnostics['longUpdateGaps'], 0);
      ticker.dispose();
    });
  }

  for (final rate in [60.0, 120.00000762939453, 120.12]) {
    testWidgets('目标达到 $rate Hz 屏幕上限时直接跟随 vsync', (tester) async {
      tester.view.display.refreshRate = rate;
      addTearDown(tester.view.display.resetRefreshRate);
      final ticker = FrameRateTicker((_) {}, frameRate: rate.round())..start();
      await tester.pump();
      expect(ticker.diagnostics['mode'], 'vsync');
      expect(ticker.diagnostics['timerWakeups'], 0);
      ticker.dispose();
      await tester.pump();
    });
  }

  testWidgets('诊断累计实际更新和请求，停止后无定时器活动', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final fixture = FrameSyncFixture(tester, 120);
    var ticks = 0;
    final ticker = _ClockTicker((_) => ticks++, fixture);
    expect(ticker.diagnostics['mode'], 'stopped');
    expect(ticker.diagnostics['lastUpdateMonotonicUs'], isNull);
    ticker.start();
    await tester.pump();
    for (var slot = 1; slot <= 120; slot++) {
      await fixture.elapseToSlot(slot);
      await fixture.pump(hasVideo: false);
    }
    final stats = ticker.diagnostics;
    expect(stats['mode'], 'independent');
    expect(stats['updates'], ticks);
    expect(ticks, closeTo(61, 1));
    expect(stats['frameRequests'], ticks);
    expect(stats['timerWakeups'], ticks - 1);
    expect(stats['lastUpdateMonotonicUs'], fixture.now);
    expect(
      stats['lastFrameRequestMonotonicUs'],
      lessThanOrEqualTo(fixture.now),
    );
    ticker.muted = true;
    expect(ticker.diagnostics['mode'], 'muted');
    ticker.stop();
    final stopped = ticker.diagnostics;
    expect(stopped['mode'], 'stopped');
    await tester.binding.delayed(const Duration(seconds: 2));
    expect(ticker.diagnostics, stopped);
    expect(tester.binding.hasScheduledFrame, isFalse);
    ticker.dispose();
  });
}

class _ClockTicker extends FrameRateTicker {
  _ClockTicker(super.onTick, this.fixture, {super.frameRate = 60});

  final FrameSyncFixture fixture;

  @override
  int get clockMicroseconds => fixture.now;
}
