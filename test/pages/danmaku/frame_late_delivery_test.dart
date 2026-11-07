import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

void main() {
  const screenPeriodUs = 8333;
  const targetIntervalUs = 16667;

  // 保留屏幕周期之前、恰好到期与刚过期三个边界。
  for (final callbackDelayUs in [8000, 8333, 8500]) {
    testWidgets('回调迟到 ${callbackDelayUs}us 后保留仍可请求的下一更新槽位', (tester) async {
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      final binding = tester.binding;
      final origin = binding.clock.now().microsecondsSinceEpoch;
      int now() => binding.clock.now().microsecondsSinceEpoch;
      final updates = <int>[];
      final ticker = _LateTicker(
        (_) => updates.add(
          binding.currentSystemFrameTimeStamp.inMicroseconds - origin,
        ),
        now,
      )..start();
      // 分开模拟引擎接收请求与 Dart 交付，回调可跨过一屏，但仍赶得上两屏后更新。
      final events = <({int at, int slot, bool deliver})>[];
      for (var slot = 1; slot <= 240; slot++) {
        events
          ..add((
            at: slot * screenPeriodUs - 500,
            slot: slot,
            deliver: false,
          ))
          ..add((
            at:
                slot * screenPeriodUs +
                (slot % 12 == 1 ? callbackDelayUs : 1000),
            slot: slot,
            deliver: true,
          ));
      }
      events.sort((a, b) => a.at.compareTo(b.at));
      int? pendingSlot;
      for (final event in events) {
        await binding.delayed(
          Duration(microseconds: origin + event.at - now()),
        );
        if (!event.deliver) {
          if (pendingSlot == null && binding.hasScheduledFrame) {
            pendingSlot = event.slot;
          }
        } else if (pendingSlot == event.slot) {
          pendingSlot = null;
          binding
            ..handleBeginFrame(
              Duration(
                microseconds: origin + (event.slot + 1) * screenPeriodUs,
              ),
            )
            ..handleDrawFrame();
        }
      }
      ticker.dispose();
      await tester.pump();
      await binding.delayed(const Duration(seconds: 2));
      final gaps = [
        for (var i = 1; i < updates.length; i++) updates[i] - updates[i - 1],
      ];
      debugPrint(
        'callbackDelay=$callbackDelayUs updates=${updates.length} '
        'gapUs=${gaps.toSet()}',
      );
      expect(gaps, everyElement(2 * screenPeriodUs));
      expect(updates.length, 120);
      expect(binding.hasScheduledFrame, isFalse);
    });
  }

  for (final lateUs in [0, 10000, 20000, 31600]) {
    testWidgets('定时唤醒迟到 ${lateUs}us 后只合并错过的槽位', (tester) async {
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      final binding = tester.binding as AutomatedTestWidgetsFlutterBinding;
      final origin = binding.clock.now().microsecondsSinceEpoch;
      int now() => binding.clock.now().microsecondsSinceEpoch - screenPeriodUs;
      final updates = <int>[];
      final ticker = _LateTicker(
        (_) => updates.add(
          binding.currentSystemFrameTimeStamp.inMicroseconds - origin,
        ),
        now,
      )..start();
      await tester.pump();

      var slot = 0;
      while (slot < 120 * 2) {
        slot++;
        var target = origin + slot * screenPeriodUs;
        if (lateUs > 0 && slot == 120) {
          // 时钟推进但不交付已经到期的 Timer，模拟主线程暂停后的迟到唤醒。
          binding.elapseBlocking(Duration(microseconds: lateUs));
          while (target <= binding.clock.now().microsecondsSinceEpoch) {
            slot++;
            target += screenPeriodUs;
          }
        }
        final delay = target - binding.clock.now().microsecondsSinceEpoch;
        if (delay > 0) {
          await binding.delayed(Duration(microseconds: delay));
        }
        if (binding.hasScheduledFrame) {
          binding
            ..handleBeginFrame(Duration(microseconds: target))
            ..handleDrawFrame();
        }
      }

      final diagnostics = ticker.diagnostics;
      ticker.dispose();
      await tester.pump();
      await binding.delayed(const Duration(seconds: 2));

      final gaps = [
        for (var i = 1; i < updates.length; i++) updates[i] - updates[i - 1],
      ];
      final longGaps = gaps
          .where((gap) => gap > targetIntervalUs + 1000)
          .toList();
      debugPrint(
        'late=$lateUs updates=${updates.length} '
        'maxGapUs=${gaps.reduce((a, b) => a > b ? a : b)} '
        'longGaps=${longGaps.length} skips=${diagnostics['deadlineSkips']}',
      );
      expect(longGaps, hasLength(lateUs == 0 ? 0 : 1));
      if (lateUs > 0) {
        expect(longGaps.single, greaterThanOrEqualTo(lateUs));
        expect(longGaps.single, lessThanOrEqualTo(lateUs + targetIntervalUs));
        final index = gaps.indexOf(longGaps.single);
        expect(
          gaps.skip(index + 1),
          everyElement(lessThanOrEqualTo(targetIntervalUs + 1000)),
        );
      }
      expect(updates.length, inInclusiveRange(115, 122));
      expect(binding.hasScheduledFrame, isFalse);
    });
  }
}

class _LateTicker extends FrameRateTicker {
  _LateTicker(super.onTick, this.now) : super(frameRate: 60);

  final int Function() now;

  @override
  int get clockMicroseconds => now();
}
