import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('90 FPS 锁定 30 FPS 视频时，在请求截止前保持目标更新率', (tester) async {
    tester.view.display.refreshRate = 120.00000762939453;
    addTearDown(tester.view.display.resetRefreshRate);
    final frames = ValueNotifier<List<int>>(const []);
    addTearDown(frames.dispose);
    final started = tester.binding.clock.now().microsecondsSinceEpoch;
    var ticks = 0;
    final ticker = _DeadlineTicker(
      (_) => ticks++,
      90,
      // Android BeginFrame 的目标时间领先回调所处时刻一个屏幕周期。
      () => tester.binding.clock.now().microsecondsSinceEpoch - 8333,
      frames,
    )..start();
    await tester.pump();
    final available = <int>[];
    var stableTicks = 0;
    for (var slot = 1; slot <= 720; slot++) {
      final deadline = started + slot * 8333 - 500;
      await tester.binding.delayed(
        Duration(
          microseconds:
              deadline - tester.binding.clock.now().microsecondsSinceEpoch,
        ),
      );
      final requested = tester.binding.hasScheduledFrame;
      await tester.binding.delayed(const Duration(microseconds: 500));
      final before = ticks;
      if (requested) await tester.pump();
      if (slot % 4 == 0) {
        available.add(started + (slot - 2) * 8333 + 1000);
      }
      if (slot % 30 == 0) {
        frames.value = available.toList();
        available.clear();
      }
      if (slot > 240) stableTicks += ticks - before;
    }
    ticker.dispose();
    await tester.pump();
    expect(stableTicks, closeTo(360, 3));
  });

  testWidgets('120 FPS 在 vsync 前关闭接收本帧请求时仍保持目标更新率', (tester) async {
    tester.view.display.refreshRate = 120.00000762939453;
    addTearDown(tester.view.display.resetRefreshRate);
    final started = tester.binding.clock.now().microsecondsSinceEpoch;
    var ticks = 0;
    final ticker = _DeadlineTicker(
      (_) => ticks++,
      120,
      () => tester.binding.clock.now().microsecondsSinceEpoch,
    )..start();
    await tester.pump();
    final initial = ticks;
    for (var slot = 1; slot <= 480; slot++) {
      final deadline = started + slot * 8333 - 500;
      await tester.binding.delayed(
        Duration(
          microseconds:
              deadline - tester.binding.clock.now().microsecondsSinceEpoch,
        ),
      );
      final requestedBeforeVsync = tester.binding.hasScheduledFrame;
      await tester.binding.delayed(const Duration(microseconds: 500));
      // 临近 vsync 才发起的请求由下一次 vsync 承载。
      if (requestedBeforeVsync) await tester.pump();
    }
    ticker.dispose();
    await tester.pump();
    expect(ticks - initial, closeTo(480, 2));
  });

  testWidgets('使用所属视图的已知刷新率，屏幕降频后限制目标帧率', (tester) async {
    // 首个视图为 60 Hz，弹幕所在视图的刷新率由调用者提供。
    tester.view.display.refreshRate = 60;
    addTearDown(tester.view.display.resetRefreshRate);
    var refreshRate = 144.0;
    var ticks = 0;
    final ticker = FrameRateTicker(
      (_) => ticks++,
      frameRate: 90,
      screenRefreshRate: () => refreshRate,
    )..start();
    await tester.pump();
    final initialTicks = ticks;
    for (var slot = 0; slot < 144; slot++) {
      await tester.binding.delayed(const Duration(microseconds: 6945));
      if (tester.binding.hasScheduledFrame) await tester.pump();
    }
    expect(ticks - initialTicks, closeTo(90, 1));
    final fastTicks = ticks;
    refreshRate = 60;
    for (var slot = 0; slot < 60; slot++) {
      await tester.binding.delayed(const Duration(microseconds: 16667));
      if (tester.binding.hasScheduledFrame) await tester.pump();
    }
    expect(ticks - fastTicks, closeTo(60, 1));
    final slowTicks = ticks;
    refreshRate = double.nan;
    for (var slot = 0; slot < 144; slot++) {
      await tester.binding.delayed(const Duration(microseconds: 6945));
      if (tester.binding.hasScheduledFrame) await tester.pump();
    }
    expect(ticks - slowTicks, closeTo(90, 1));
    ticker.dispose();
    await tester.binding.delayed(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('60 FPS 弹幕复用同相位 Dart 帧，帧内耗时不应错过下一帧', (tester) async {
    final ticks = <Duration>[];
    final animation = Ticker((_) {})..start();
    final ticker = FrameRateTicker((elapsed) {
      ticks.add(elapsed);
      // 模拟更新弹幕时的同步耗时；其它 Dart 动画继续提供帧回调。
      (tester.binding as AutomatedTestWidgetsFlutterBinding).elapseBlocking(
        const Duration(milliseconds: 1),
      );
    }, frameRate: 60)..start();
    await tester.pump();
    await tester.pump(const Duration(microseconds: 15667));
    expect(ticks, [Duration.zero, const Duration(microseconds: 16667)]);
    ticker.dispose();
    animation.dispose();
  });

  testWidgets('同相位 Dart 帧承载弹幕后取消后续定时刷新请求', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final ticks = <Duration>[];
    final ticker = FrameRateTicker((elapsed) {
      ticks.add(elapsed);
      (tester.binding as AutomatedTestWidgetsFlutterBinding).elapseBlocking(
        const Duration(milliseconds: 1),
      );
    }, frameRate: 60)..start();
    await tester.pump();
    // 模拟外部请求下一张 Dart 帧，没有持续运行的 Flutter 动画。
    tester.binding.scheduleFrame();
    await tester.pump(const Duration(microseconds: 15667));
    await tester.binding.delayed(const Duration(milliseconds: 2));
    expect(ticks.length, 2);
    expect(tester.binding.hasScheduledFrame, isFalse);
    ticker.dispose();
  });

  for (final fps in [60, 120]) {
    testWidgets('$fps FPS 减少帧请求并保持实际经过时间', (tester) async {
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      final ticks = <Duration>[];
      final ticker = FrameRateTicker(ticks.add, frameRate: fps)..start();
      await tester.pump();
      expect(ticks, [Duration.zero]);
      // 达到屏幕上限时直接请求 vsync；较低档位等待定时唤醒。
      expect(tester.binding.hasScheduledFrame, fps == 120);
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(microseconds: 8334));
      }
      expect(ticks.length - 1, closeTo(fps, 1));
      expect(ticks.last.inMilliseconds, closeTo(1000, 34));
      ticker.dispose();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  }

  testWidgets('暂停、静音和档位切换会取消等待中的帧请求', (tester) async {
    final ticks = <Duration>[];
    final ticker = FrameRateTicker(ticks.add, frameRate: 60)..start();
    await tester.pump();
    ticker.stop();
    await tester.pump(const Duration(seconds: 1));
    expect(ticks.length, 1);
    expect(tester.binding.hasScheduledFrame, isFalse);

    ticker.start();
    await tester.pump();
    ticker.muted = true;
    await tester.pump(const Duration(seconds: 1));
    expect(ticks.length, 2);
    expect(tester.binding.hasScheduledFrame, isFalse);
    ticker.frameRate = 90;
    expect(ticker.muted, isTrue);
    ticker.muted = false;
    await tester.pump();
    expect(ticks.length, 3);
    ticker.dispose();
  });

  testWidgets('跟随屏幕逐帧更新', (tester) async {
    final ticks = <Duration>[];
    final ticker = FrameRateTicker(ticks.add)..start();
    await tester.pump();
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(microseconds: 8334));
    }
    expect(ticks.length, 121);
    ticker.dispose();
  });
}

class _DeadlineTicker extends FrameRateTicker {
  _DeadlineTicker(
    super.onTick,
    int fps,
    this.now, [
    ValueNotifier<List<int>>? frames,
  ]) : super(frameRate: fps, videoFrameTimings: frames);

  final int Function() now;

  @override
  int get clockMicroseconds => now();
}
