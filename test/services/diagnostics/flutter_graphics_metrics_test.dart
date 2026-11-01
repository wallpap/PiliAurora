import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/flutter_graphics_metrics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'real image clone and picture lifetimes count handles and nominal bytes',
    () {
      final metrics = FlutterGraphicsMetrics(maxResources: 2)..start();
      addTearDown(metrics.stop);
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawColor(const ui.Color(0xff000000), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(10, 20);
      final clone = image.clone();
      final snapshot = metrics.snapshot();
      expect((snapshot['image'] as Map)['currentHandles'], 2);
      expect((snapshot['image'] as Map)['currentBytes'], 1600);
      expect((snapshot['picture'] as Map)['currentHandles'], 1);
      expect(
        (snapshot['picture'] as Map)['currentBytes'],
        picture.approximateBytesUsed,
      );
      expect((snapshot['largestResources'] as List).length, 2);
      image.dispose();
      clone.dispose();
      picture.dispose();
      final ended = metrics.snapshot();
      expect((ended['image'] as Map)['explicitlyDisposed'], 2);
      expect((ended['image'] as Map)['currentHandles'], 0);
      expect((ended['image'] as Map)['peakBytes'], 1600);
      expect((ended['picture'] as Map)['currentBytes'], 0);
    },
  );

  test(
    'forwards and restores hooks, preserves replacements and isolates restart',
    () {
      final oldCreate = ui.Picture.onCreate;
      final oldDispose = ui.Picture.onDispose;
      var created = 0, disposed = 0;
      void beforeCreate(ui.Picture _) {
        created++;
      }

      void beforeDispose(ui.Picture _) {
        disposed++;
      }

      void replacement(ui.Picture _) {}
      ui.Picture.onCreate = beforeCreate;
      ui.Picture.onDispose = beforeDispose;
      final metrics = FlutterGraphicsMetrics(useFrameworkEvents: false);
      addTearDown(() {
        metrics.stop();
        ui.Picture.onCreate = oldCreate;
        ui.Picture.onDispose = oldDispose;
      });
      metrics.start();
      final firstRecorder = ui.PictureRecorder();
      ui.Canvas(firstRecorder);
      final first = firstRecorder.endRecording();
      metrics.stop();
      expect(ui.Picture.onCreate, beforeCreate);
      expect(ui.Picture.onDispose, beforeDispose);
      metrics.start();
      first.dispose();
      expect((metrics.snapshot()['picture'] as Map)['explicitlyDisposed'], 0);
      final secondRecorder = ui.PictureRecorder();
      ui.Canvas(secondRecorder);
      secondRecorder.endRecording().dispose();
      expect(created, 2);
      expect(disposed, 2);
      expect((metrics.snapshot()['picture'] as Map)['created'], 1);
      ui.Picture.onCreate = replacement;
      metrics.stop();
      expect(ui.Picture.onCreate, replacement);
      expect(ui.Picture.onDispose, beforeDispose);
    },
  );

  test('framework listeners can subscribe and unsubscribe during tracing', () {
    final metrics = FlutterGraphicsMetrics()..start();
    addTearDown(metrics.stop);
    var count = 0;
    void listener(ObjectEvent event) {
      if (event is ObjectCreated && event.object is ui.Picture) count++;
    }

    FlutterMemoryAllocations.instance.addListener(listener);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final picture = recorder.endRecording();
    FlutterMemoryAllocations.instance.removeListener(listener);
    picture.dispose();
    expect(count, 1);
    expect((metrics.snapshot()['picture'] as Map)['explicitlyDisposed'], 1);
  });
}
