import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter_test/flutter_test.dart';

import 'dart:ui';

void main() {
  testWidgets('原生到达相位独立于 mpv 同步状态，停止后释放状态订阅', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final frames = ValueNotifier<List<int>>(const []);
    final syncActive = _DisplaySyncState(false);
    addTearDown(frames.dispose);
    addTearDown(syncActive.dispose);
    final origin = tester.binding.clock.now().microsecondsSinceEpoch;
    var ticks = 0;
    final ticker = _ClockTicker(
      (_) => ticks++,
      () => tester.binding.clock.now().microsecondsSinceEpoch,
      frames,
      syncActive,
    )..start();
    await tester.pump();
    expect(syncActive.observed, isTrue);
    final initialTicks = ticks;
    final updates = [0, 0, 0, 0];
    final combined = [0, 0, 0, 0];
    final available = <int>[];
    for (var slot = 1; slot <= 1440; slot++) {
      await tester.binding.delayed(const Duration(microseconds: 8334));
      final segment = (slot - 1) ~/ 360;
      if ((slot - 1) % 360 == 0) syncActive.value = segment.isOdd;
      // mpv 同步关闭期间改变视频相位，仍按实际到达通知重新对齐。
      final hasVideo = slot % 2 == (segment < 2 ? 1 : 0);
      if (hasVideo) {
        available.add(origin + (slot - 2) * 8334 + 1000);
      }
      final previousTicks = ticks;
      final hasDart = tester.binding.hasScheduledFrame;
      if (hasDart) await tester.pump();
      if (slot % 30 == 0) {
        frames.value = available.toList();
        available.clear();
      }
      if ((slot - 1) % 360 >= 120) {
        updates[segment] += ticks - previousTicks;
        if (hasVideo || hasDart) combined[segment]++;
      }
    }
    ticker.stop();
    expect(syncActive.observed, isFalse);
    ticker.start();
    expect(syncActive.observed, isTrue);
    ticker.dispose();
    expect(syncActive.observed, isFalse);
    await tester.pump();
    await tester.binding.delayed(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(ticks - initialTicks, closeTo(720, 4));
    for (var segment = 0; segment < 4; segment++) {
      expect(updates[segment], closeTo(120, 2));
      expect(combined[segment], closeTo(120, 2));
    }
    debugPrint('display sync state: updates=$updates combined=$combined');
  });

  testWidgets('视频周期匹配、失配再匹配时，弹幕退化后恢复同步', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final frames = ValueNotifier<List<int>>(const []);
    addTearDown(frames.dispose);
    final origin = tester.binding.clock.now().microsecondsSinceEpoch;
    var ticks = 0;
    final ticker = _ClockTicker(
      (_) => ticks++,
      () => tester.binding.clock.now().microsecondsSinceEpoch,
      frames,
    )..start();
    await tester.pump();
    final initialTicks = ticks;
    final updates = [0, 0, 0];
    final combined = [0, 0, 0];
    final available = <int>[];
    for (var slot = 1; slot <= 1080; slot++) {
      await tester.binding.delayed(const Duration(microseconds: 8334));
      // 不清空采样，直接从 60 切到 24 再切到 30 FPS。
      final segment = (slot - 1) ~/ 360;
      final videoRate = [60, 24, 30][segment];
      final hasVideo = slot % (120 ~/ videoRate) == 1;
      if (hasVideo) {
        available.add(origin + (slot - 2) * 8334 + 1000);
      }
      final previousTicks = ticks;
      final hasDart = tester.binding.hasScheduledFrame;
      if (hasDart) await tester.pump();
      if (slot % 30 == 0) {
        frames.value = available.toList();
        available.clear();
      }
      if ((slot - 1) % 360 >= 120) {
        updates[segment] += ticks - previousTicks;
        if (hasVideo || hasDart) combined[segment]++;
      }
    }
    ticker.dispose();
    await tester.binding.delayed(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(ticks - initialTicks, closeTo(540, 3));
    for (var segment = 0; segment < 3; segment++) {
      expect(updates[segment], closeTo(120, 2));
      expect(combined[segment], closeTo(segment == 1 ? 144 : 120, 2));
    }
    debugPrint('sync / fallback / sync: updates=$updates combined=$combined');
  });

  testWidgets(
    '30 FPS 视频相位变化后，60 FPS 弹幕恢复合帧，'
    '120 Hz，timing 批次=120',
    (tester) async {
      const refreshRate = 120.0;
      const batchSlots = 120;
      tester.view.display.refreshRate = refreshRate;
      addTearDown(tester.view.display.resetRefreshRate);
      final frames = ValueNotifier<List<int>>(const []);
      addTearDown(frames.dispose);
      final origin = tester.binding.clock.now().microsecondsSinceEpoch;
      var ticks = 0;
      final ticker = _ClockTicker(
        (_) => ticks++,
        () => tester.binding.clock.now().microsecondsSinceEpoch,
        frames,
      )..start();
      await tester.pump();
      final initialTicks = ticks;
      final available = <int>[];
      var alignedSlots = 0;
      var shiftedSlots = 0;
      final slotsPerSecond = refreshRate.toInt();
      final videoSlots = slotsPerSecond ~/ 30;
      final slotMicros = (1000000 / refreshRate).ceil();
      for (var slot = 1; slot <= slotsPerSecond * 6; slot++) {
        await tester.binding.delayed(Duration(microseconds: slotMicros));
        // 前三秒视频与弹幕同相位，随后视频输出错开一个屏幕槽位。
        final hasVideo =
            slot % videoSlots == (slot <= slotsPerSecond * 3 ? 0 : 1);
        if (hasVideo) {
          available.add(origin + (slot - 2) * slotMicros + 1000);
        }
        final hasDart = tester.binding.hasScheduledFrame;
        if (hasDart) await tester.pump();
        if (slot % batchSlots == 0) {
          frames.value = available.toList();
          available.clear();
        }
        if (hasVideo || hasDart) {
          if (slot > slotsPerSecond && slot <= slotsPerSecond * 3) {
            alignedSlots++;
          }
          if (slot > slotsPerSecond * 4) shiftedSlots++;
        }
      }
      ticker.dispose();
      await tester.binding.delayed(const Duration(seconds: 2));
      expect(tester.binding.hasScheduledFrame, isFalse);
      debugPrint(
        '30fps video / 60fps danmaku: aligned=$alignedSlots/2s '
        'shifted=$shiftedSlots/2s danmaku=${ticks - initialTicks}/6s',
      );
      expect(ticks - initialTicks, closeTo(360, 3));
      expect(alignedSlots, inInclusiveRange(118, 122));
      expect(shiftedSlots, inInclusiveRange(118, 122));
    },
  );

  testWidgets('原生来源按播放器替换，停止和销毁时释放订阅', (tester) async {
    final first = _NativeFrames();
    final second = _NativeFrames();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final ticker = _ClockTicker(
      (_) {},
      () => tester.binding.clock.now().microsecondsSinceEpoch,
      first,
    )..start();
    await tester.pump();
    expect(first.observed, isTrue);
    ticker.videoFrameTimings = second;
    expect(first.observed, isFalse);
    expect(second.observed, isTrue);
    ticker.stop();
    expect(second.observed, isFalse);
    ticker.start();
    expect(second.observed, isTrue);
    ticker.dispose();
    expect(second.observed, isFalse);
    await tester.pump();
    await tester.binding.delayed(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('停止时切源清空采样后放弃旧相位', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final frames = ValueNotifier<List<int>>(const []);
    addTearDown(frames.dispose);
    final ticker = _ClockTicker(
      (_) {},
      () => tester.binding.clock.now().microsecondsSinceEpoch,
      frames,
    )..start();
    await tester.pump();
    final now = tester.binding.clock.now().microsecondsSinceEpoch;
    frames.value = [now - 33336 + 700, now - 16668 + 700];
    ticker.stop();
    frames.value = const [];
    ticker.start();
    expect(tester.binding.hasScheduledFrame, isTrue);
    ticker.dispose();
    await tester.pump();
    await tester.binding.delayed(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
  for (final offset in [-2000000, 100000]) {
    testWidgets('过期或时钟不匹配的原生批次不锁定相位，offset=$offset', (tester) async {
      final frames = ValueNotifier<List<int>>(const []);
      addTearDown(frames.dispose);
      final ticker = _ClockTicker(
        (_) {},
        () => tester.binding.clock.now().microsecondsSinceEpoch,
        frames,
      )..start();
      await tester.pump();
      final now = tester.binding.clock.now().microsecondsSinceEpoch;
      frames.value = [now + offset - 16668, now + offset];
      ticker
        ..stop()
        ..start();
      expect(tester.binding.hasScheduledFrame, isTrue);
      ticker.dispose();
      await tester.pump();
      await tester.binding.delayed(const Duration(seconds: 2));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  }
  // 使用真实 FrameRateTicker 和 Flutter 测试时钟。纹理帧用时间槽记录，
  // 模拟独立的原生刷新源；这里不创建 GPU 纹理，也不测量屏幕实际 Hz。
  const batchSlots = 120;
  for (final videoRunsDart in [false, true]) {
    for (final videoPhase in [0, 1]) {
      testWidgets(
        '60 FPS 视频${videoRunsDart ? '提供' : '不提供'} Dart 帧，'
        '${videoPhase == 0 ? '同相位' : '错开半周期'}，timing 批次=$batchSlots',
        (tester) async {
          var danmakuUpdates = 0;
          tester.view.display.refreshRate = 120;
          addTearDown(tester.view.display.resetRefreshRate);
          final origin = tester.binding.clock.now();
          final nativeFrames = ValueNotifier<List<int>>(const []);
          addTearDown(nativeFrames.dispose);
          final ticker = _ClockTicker(
            (_) => danmakuUpdates++,
            () => tester.binding.clock.now().microsecondsSinceEpoch,
            nativeFrames,
          )..start();
          await tester.pump();
          final initialUpdates = danmakuUpdates;
          var videoFrames = 0;
          var dartFrames = 0;
          var combinedSlots = 0;
          var extraSlots = 0;
          var steadyExtra = 0;
          final timings = <FrameTiming>[];
          final available = <int>[];

          // 120 Hz 的 360 个槽位约为三秒，覆盖 release 的一秒报告批次。
          // 只有应用实际请求帧才 pump，避免测试自身逐槽驱动弹幕。
          for (var slot = 1; slot <= 360; slot++) {
            await tester.binding.delayed(const Duration(microseconds: 8334));
            final hasVideoFrame = slot % 2 == videoPhase;
            if (hasVideoFrame) {
              videoFrames++;
              available.add(
                origin.microsecondsSinceEpoch +
                    (slot - 2) * 8334 +
                    700 +
                    (slot % 3) * 1200,
              );
              if (videoRunsDart) tester.binding.scheduleFrame();
            }
            final hasDartFrame = tester.binding.hasScheduledFrame;
            if (hasDartFrame) {
              dartFrames++;
              await tester.pump();
            }
            if (hasDartFrame) {
              final stamp = origin.microsecondsSinceEpoch + slot * 8334 - 8333;
              timings.add(
                FrameTiming(
                  vsyncStart: stamp,
                  buildStart: stamp + 1,
                  buildFinish: stamp + (hasDartFrame ? 2 : 1),
                  rasterStart: stamp + 3,
                  rasterFinish: stamp + 4,
                  rasterFinishWallTime: stamp + 4,
                ),
              );
            }
            if (slot % batchSlots == 0) {
              tester.binding.platformDispatcher.onReportTimings?.call(
                timings.toList(),
              );
              timings.clear();
              nativeFrames.value = available.sublist(
                available.length > 32 ? available.length - 32 : 0,
              );
              available.clear();
            }
            if (hasVideoFrame || hasDartFrame) combinedSlots++;
            if (!hasVideoFrame && hasDartFrame) extraSlots++;
            if (slot > batchSlots + 24 && !hasVideoFrame && hasDartFrame) {
              steadyExtra++;
            }
          }
          ticker.dispose();
          await tester.binding.delayed(const Duration(seconds: 1));
          expect(tester.binding.hasScheduledFrame, isFalse);

          expect(videoFrames, 180);
          expect(danmakuUpdates - initialUpdates, inInclusiveRange(177, 182));
          // 相位学习允许起始阶段的额外请求，稳定后必须消除夹帧。
          debugPrint(
            'native-frame-timings video=$videoFrames danmaku=${danmakuUpdates - initialUpdates} combined=$combinedSlots extra=$extraSlots steadyExtra=$steadyExtra',
          );
          expect(steadyExtra, 0);
          const startupAllowance = batchSlots ~/ 2 + 2;
          expect(combinedSlots, lessThanOrEqualTo(180 + startupAllowance));
          expect(extraSlots, lessThanOrEqualTo(startupAllowance));
          debugPrint(
            'videoDart=$videoRunsDart phase=$videoPhase '
            'video=$videoFrames danmaku=${danmakuUpdates - initialUpdates} '
            'dart=$dartFrames combined=$combinedSlots extra=$extraSlots',
          );
        },
      );
    }
  }
  testWidgets('29.97 FPS 在 120 Hz 上漂移时持续跟随原生相位', (tester) async {
    const videoRate = 29.97;
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final frames = ValueNotifier<List<int>>(const []);
    addTearDown(frames.dispose);
    final origin = tester.binding.clock.now().microsecondsSinceEpoch;
    var ticks = 0;
    final ticker = _ClockTicker(
      (_) => ticks++,
      () => tester.binding.clock.now().microsecondsSinceEpoch,
      frames,
    )..start();
    await tester.pump();
    final initialTicks = ticks;
    var videoFrames = 0;
    var extraSlots = 0;
    var nextVideo = 8334.0;
    final available = <int>[];
    for (var slot = 1; slot <= 1800; slot++) {
      await tester.binding.delayed(const Duration(microseconds: 8334));
      final hasVideo = slot * 8334 >= nextVideo;
      if (hasVideo) {
        nextVideo += 1000000 / videoRate;
        videoFrames++;
        available.add(origin + (slot - 2) * 8334 + 1000);
      }
      final hasDart = tester.binding.hasScheduledFrame;
      if (hasDart) await tester.pump();
      if (hasDart && !hasVideo) extraSlots++;
      if (slot % 30 == 0) {
        frames.value = available.toList();
        available.clear();
      }
    }
    ticker.dispose();
    await tester.binding.delayed(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
    // 起步及视频跨到相邻槽位时，需要等待下一份 250 ms 原生批次。
    final subdivisions = (60 / videoRate).round();
    expect(
      extraSlots,
      lessThanOrEqualTo(videoFrames * (subdivisions - 1) + 34),
    );
    expect(ticks - initialTicks, closeTo(videoFrames * subdivisions, 3));
    debugPrint(
      '${videoRate}fps video=$videoFrames danmaku=${ticks - initialTicks} extra=$extraSlots',
    );
  });
}

class _ClockTicker extends FrameRateTicker {
  _ClockTicker(
    super.onTick,
    this.now, [
    ValueListenable<List<int>>? frames,
    ValueListenable<bool>? syncActive,
  ]) : super(
         frameRate: 60,
         videoFrameTimings: frames,
         videoDisplaySyncActive: syncActive,
       );
  final int Function() now;
  @override
  // pump 的时间作为 BeginFrame 目标；实际交付与原生请求使用前一屏时钟。
  int get clockMicroseconds =>
      now() -
      (1000000 /
              SchedulerBinding
                  .instance
                  .platformDispatcher
                  .views
                  .first
                  .display
                  .refreshRate)
          .round();
}

class _DisplaySyncState extends ValueNotifier<bool> {
  _DisplaySyncState(super.value);
  bool get observed => hasListeners;
}

class _NativeFrames extends ValueNotifier<List<int>> {
  _NativeFrames() : super(const []);
  bool get observed => hasListeners;
}
