import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final capture = jsonDecode(
    File(
      'test/pages/danmaku/fixtures/cadence_boundary.json',
    ).readAsStringSync(),
  ) as Map<String, dynamic>;
  final callbacks = (capture['events'] as List)
      .cast<List>()
      .where((row) => row[1] == 'frame')
      .toList();
  // 捕获中两个回调之间可能相隔两个槽位，插值得到未请求的中间槽位。
  final slots = <int>[0];
  for (var i = 1; i < callbacks.length; i++) {
    final delta = (callbacks[i][2] as int) - (callbacks[i - 1][2] as int);
    final count = (delta / 8333).round();
    final base = slots.last;
    for (var j = 1; j <= count; j++) {
      slots.add(base + (delta * j / count).round());
    }
  }
  final callbackLags = [
    for (final row in callbacks) (row[0] as int) - (row[2] as int) + 8333,
  ];
  final maxSlotUs = [
    for (var i = 1; i < slots.length; i++) slots[i] - slots[i - 1],
  ].reduce(math.max);
  for (final reportedHz in [119.88, 120.00000762939453, 120.12]) {
    for (final target in [0, 60, 90, 120]) {
      for (final videoRate in [29.97, 59.94]) {
        for (final delayedBatch in [false, true]) {
          testWidgets('实测槽位 Android 刷新率读数 $reportedHz Hz / $target FPS / '
              '视频 $videoRate FPS，延迟批次=$delayedBatch', (tester) async {
            tester.view.display.refreshRate = reportedHz;
            addTearDown(tester.view.display.resetRefreshRate);
            final origin = tester.binding.clock.now().microsecondsSinceEpoch;
            int clock() => tester.binding.clock.now().microsecondsSinceEpoch;
            // BeginFrame 使用目标时间；Dart 实际执行时间另受回调迟到影响。
            int now() => clock() - 8333;
            final frames = ValueNotifier<List<int>>(const []);
            final updates = <int>[];
            final ticker = _DeviceTicker(
              (_) => updates.add(
                tester.binding.currentSystemFrameTimeStamp.inMicroseconds -
                    origin,
              ),
              now,
              frames,
              target,
            )..start();
            await tester.pump();
            var nextVideo = 1000000 / videoRate;
            final available = <int>[];
            var nextBatch = delayedBatch ? 1000000 : 250000;
            var batchIndex = 0;
            var combined = 0;
            var videoCount = 0;
            var phaseChanged = false;
            final observed = <int>[];
            var span = 0;
            for (var slot = 1; slot <= 120 * 8; slot++) {
              final cycle = (slot - 1) ~/ (slots.length - 1);
              final index = (slot - 1) % (slots.length - 1) + 1;
              final stamp = cycle * slots.last + slots[index];
              span = stamp;
              await tester.binding.delayed(
                Duration(
                  microseconds: origin + stamp - 500 - clock(),
                ),
              );
              final requested = tester.binding.hasScheduledFrame;
              if (!phaseChanged && stamp >= 4000000) {
                nextVideo += 8333;
                phaseChanged = true;
              }
              final video = stamp >= nextVideo;
              if (video) {
                nextVideo += 1000000 / videoRate;
                videoCount++;
                available.add(origin + stamp - 2 * 8333 + 1000);
              }
              // 延迟批次场景另加入本包全窗口观测到的约 5.7ms 回调迟到。
              final lag = delayedBatch && slot % 67 == 0
                  ? 5700
                  : callbackLags[slot % callbackLags.length];
              await tester.binding.delayed(
                Duration(
                  microseconds: origin + stamp + lag - clock(),
                ),
              );
              if (requested || video) {
                tester.binding.handleBeginFrame(
                  Duration(microseconds: origin + stamp),
                );
                tester.binding.handleDrawFrame();
              }
              if (stamp >= nextBatch) {
                frames.value = available.toList();
                available.clear();
                // 250ms 实际原生批次与 1s 积压压力分别覆盖；到达存在抖动。
                nextBatch +=
                    (delayedBatch ? 1000000 : 250000) +
                    const [0, 16000, -3500][batchIndex++ % 3];
              }
              if (stamp > 2000000) {
                if (requested || video) combined++;
                if (video) observed.add(stamp);
              }
            }
            final diagnostics = ticker.diagnostics;
            ticker.dispose();
            frames.dispose();
            // 引擎已接受的最后一次请求仍需交付，ticker 不再注册新回调。
            await tester.pump();
            await tester.binding.delayed(const Duration(seconds: 2));
            final steady = updates.where((t) => t > 2000000).toList();
            final effective = target == 0
                ? 120.0
                : math.min(target, 120).toDouble();
            final expected = effective * (span - 2000000) / 1000000;
            final maxSlots = (120 / effective).ceil();
            final maxGap = [
              for (var i = 1; i < steady.length; i++) steady[i] - steady[i - 1],
            ].reduce(math.max);
            debugPrint(
              'device matrix hz=$reportedHz target=$target video=$videoRate '
              'delayed=$delayedBatch updates=${steady.length}/$expected '
              'maxGapUs=$maxGap combined=$combined video=${observed.length} '
              'nativeTotal=$videoCount skips=${diagnostics['deadlineSkips']}',
            );
            expect(steady.length, closeTo(expected, 3));
            expect(maxGap, lessThanOrEqualTo(maxSlots * maxSlotUs));
            final shared = steady.length + observed.length - combined;
            expect(
              shared,
              greaterThanOrEqualTo(
                math.min(steady.length, observed.length) / 2,
              ),
            );
            if (target == 0 || target == 120) {
              expect(combined, steady.length);
            }
            expect(tester.binding.hasScheduledFrame, isFalse);
          });
        }
      }
    }
  }
}

class _DeviceTicker extends FrameRateTicker {
  _DeviceTicker(
    super.onTick,
    this.now,
    ValueListenable<List<int>> frames,
    int target,
  ) : super(frameRate: target, videoFrameTimings: frames);
  final int Function() now;
  @override
  int get clockMicroseconds => now();
}
