import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/flutter_graphics_metrics.dart';

void main() {
  testWidgets('idle cache clear releases image handles after the next frame', (
    tester,
  ) async {
    final cache = PaintingBinding.instance.imageCache..clear();
    await tester.pumpAndSettle();
    final metrics = FlutterGraphicsMetrics()..start();
    addTearDown(metrics.stop);
    final image = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(16, 16);
      } finally {
        picture.dispose();
      }
    });
    final completer = cache.putIfAbsent(
      Object(),
      () =>
          OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image!))),
    )!;
    final listener = ImageStreamListener((info, _) => info.dispose());
    completer.addListener(listener);
    await tester.pumpAndSettle();
    completer.removeListener(listener);
    tester.binding.scheduleFrame();
    await tester.pumpAndSettle();
    expect(cache.liveImageCount, 0);
    expect(cache.currentSize, 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
    final before = metrics.snapshot()['image'] as Map;
    expect(before['currentHandles'], greaterThan(0));

    // 模拟定时器/诊断动作在静止页面调用clear。SDK有意延迟释放到postFrame，
    // cacheBytes归零和等待真实时间都不能代替一帧。
    await tester.runAsync(() async {
      cache.clear();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(cache.currentSizeBytes, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    final cleared = metrics.snapshot()['image'] as Map;
    expect(cleared['currentHandles'], before['currentHandles']);
    expect(cleared['explicitlyDisposed'], before['explicitlyDisposed']);

    tester.binding.scheduleFrame();
    await tester.pump();
    final afterFrame = metrics.snapshot()['image'] as Map;
    expect(afterFrame['currentHandles'], 0);
    expect(afterFrame['explicitlyDisposed'], afterFrame['created']);
  });
}
