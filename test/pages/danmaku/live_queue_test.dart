import 'dart:async';
import 'dart:ui' as ui;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/live_queue.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';

void main() {
  for (final invalidation in ['deadline', 'clear', 'dispose']) {
    test(
      'domain predicate expires before late encoded input after $invalidation',
      () async {
        var now = 0;
        final file = Completer<void>();
        bool Function()? valid;
        var decoders = 0;
        var fallbackCalls = 0;
        final queue =
            LiveDanmakuQueue<void>(
                nowUs: () => now,
                loadImage: (_) async {
                  fallbackCalls++;
                  return null;
                },
                loadImageIfCurrent: (emote, isCurrent) async {
                  valid = isCurrent;
                  await file.future;
                  if (!isCurrent()) return null;
                  decoders++;
                  return null;
                },
                admit: (_) => false,
                wake: () {},
              )
              ..add(
                const LiveDanmakuMessage(
                  identity: 1,
                  receivedAtUs: 0,
                  text: '[x]',
                  emotes: [LiveEmoteDescriptor('[x]', 'x', 12, 12)],
                ),
              )
              ..process(running: true, fontSize: 20);
        expect(valid!(), isTrue);
        if (invalidation == 'deadline') now = 300001;
        if (invalidation == 'clear') queue.clear();
        if (invalidation == 'dispose') queue.dispose();
        expect(valid!(), isFalse);
        expect(queue.runningTasks, 1);
        file.complete();
        await Future<void>.delayed(Duration.zero);
        expect(decoders, 0);
        expect(fallbackCalls, 0);
        expect(queue.runningTasks, 0);
        queue.dispose();
      },
    );
  }
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'queue reservations share the renderer total and stop before decoding',
    () {
      var loads = 0;
      late final LiveDanmakuQueue<void> queue;
      final renderer = DanmakuWindowRenderer<void>(
        option: const DanmakuOption(),
        size: const ui.Size(320, 120),
        maxWorkingSetBytes: 256 * 1024,
        additionalWorkingSetBytes: (images) =>
            queue.workingSetBytesExcluding(images),
      );
      addTearDown(renderer.dispose);
      queue = LiveDanmakuQueue<void>(
        nowUs: () => 0,
        loadImage: (_) async {
          loads++;
          return null;
        },
        admit: (_) => true,
        wake: () {},
        canReserveBytes: (bytes) =>
            renderer.workingSetBytes + bytes <= renderer.maxWorkingSetBytes,
      );
      addTearDown(queue.dispose);
      queue.add(
        const LiveDanmakuMessage(
          identity: 'emote',
          receivedAtUs: 0,
          text: '[e]',
          emotes: [LiveEmoteDescriptor('[e]', 'url', 16, 16)],
        ),
      );
      expect(queue.candidateCount, 1);
      queue.process(running: true, fontSize: 20);
      expect(loads, 0);
      expect(queue.runningTasks, 0);
      expect(queue.hasReady, isFalse);
      expect(
        renderer.workingSetBytes,
        lessThanOrEqualTo(renderer.maxWorkingSetBytes),
      );
      queue.clear();
      expect(renderer.workingSetBytes, 0);
    },
  );
  test(
    'ready emote transfers its reservation to owned renderer sources',
    () async {
      final pending = Completer<ui.Image?>();
      late final LiveDanmakuQueue<void> queue;
      final renderer = DanmakuWindowRenderer<void>(
        option: const DanmakuOption(),
        size: const ui.Size(320, 120),
        maxWorkingSetBytes: 768 * 1024,
        additionalWorkingSetBytes: (images) =>
            queue.workingSetBytesExcluding(images),
      );
      addTearDown(renderer.dispose);
      queue = LiveDanmakuQueue<void>(
        nowUs: () => 0,
        loadImage: (_) => pending.future,
        admit: (item) {
          final prepared = renderer.prepare(
            [DanmakuWindowContent('emote', 0, item)],
            generation: renderer.generation,
            preparedUntilUs: 3000000,
          );
          renderer.present(500000);
          item.dispose();
          return prepared;
        },
        wake: () {},
        canReserveBytes: (bytes) =>
            renderer.workingSetBytes + bytes <= renderer.maxWorkingSetBytes,
      );
      addTearDown(queue.dispose);
      queue
        ..add(
          const LiveDanmakuMessage(
            identity: 'emote',
            receivedAtUs: 0,
            text: '[e]',
            emotes: [LiveEmoteDescriptor('[e]', 'url', 16, 16)],
          ),
        )
        ..process(running: true, fontSize: 20);
      expect(queue.runningTasks, 1);
      expect(
        renderer.workingSetBytes,
        greaterThanOrEqualTo(LiveDanmakuQueue.taskReservationBytes),
      );
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawColor(const ui.Color(0xffff0000), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(128, 128);
      picture.dispose();
      pending.complete(image);
      await Future<void>.delayed(Duration.zero);
      expect(queue.runningTasks, 0);
      expect(queue.reservedBytes, 128 * 128 * 4);
      queue.process(running: true, fontSize: 20);
      expect(image.debugDisposed, isTrue);
      expect(queue.workingSetBytes, 0);
      expect(renderer.activeCount, 1);
      expect(renderer.workingSetBytes, greaterThanOrEqualTo(128 * 128 * 4));
      expect(
        renderer.workingSetBytes,
        lessThanOrEqualTo(renderer.maxWorkingSetBytes),
      );
      renderer.reset(3000000);
      expect(renderer.statistics['active'], 0);
    },
  );
  test(
    'resource reservation covers retained images and the next decoded image',
    () async {
      ui.Image image() {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder)
            .drawColor(const ui.Color(0xffff0000), ui.BlendMode.src);
        final picture = recorder.endRecording();
        final result = picture.toImageSync(256, 256);
        picture.dispose();
        return result;
      }

      final first = image();
      final second = image();
      final next = Completer<ui.Image?>();
      var requests = 0;
      final queue = LiveDanmakuQueue<void>(
        nowUs: () => 0,
        loadImage: (_) {
          requests++;
          return requests == 1 ? Future.value(first) : next.future;
        },
        admit: (_) => false,
        wake: () {},
      );
      addTearDown(queue.dispose);
      queue
        ..add(
          const LiveDanmakuMessage(
            identity: 'pair',
            receivedAtUs: 0,
            text: '[a][b]',
            emotes: [
              LiveEmoteDescriptor('[a]', 'a', 16, 16),
              LiveEmoteDescriptor('[b]', 'b', 16, 16),
            ],
          ),
        )
        ..process(running: true, fontSize: 20);
      await Future<void>.delayed(Duration.zero);
      expect(requests, 2);
      expect(queue.runningTasks, 1);
      expect(queue.reservedBytes, LiveDanmakuQueue.taskReservationBytes);
      expect(first.debugDisposed, isFalse);
      next.complete(second);
      await Future<void>.delayed(Duration.zero);
      expect(second.debugDisposed, isTrue);
      expect(queue.runningTasks, 0);
      expect(queue.reservedBytes, LiveDanmakuQueue.maxCandidateImageBytes);
      queue.clear();
      expect(first.debugDisposed, isTrue);
      expect(queue.reservedBytes, 0);
    },
  );
  test('burst keeps latest candidates and original monotonic expiry', () {
    var now = 0;
    final accepted = <String>[];
    final queue = LiveDanmakuQueue<void>(
      nowUs: () => now,
      loadImage: (_) async => null,
      wake: () {},
      maxCandidates: 2,
      admit: (item) {
        accepted.add(item.text);
        return true;
      },
    );
    for (var i = 0; i < 4; i++) {
      queue.add(LiveDanmakuMessage(identity: i, receivedAtUs: 0, text: '$i'));
    }
    expect(queue.candidateCount, 2);
    now = 1000000;
    queue.process(running: true, fontSize: 20);
    expect(accepted, isEmpty);
    expect(queue.candidateCount, 0);
    queue.dispose();
  });
  test(
    'slow emote keeps task slot after fallback and never enters twice',
    () async {
      var now = 0;
      final pending = Completer<ui.Image?>();
      final accepted = <DanmakuContentItem<void>>[];
      final queue =
          LiveDanmakuQueue<void>(
              nowUs: () => now,
              loadImage: (_) => pending.future,
              wake: () {},
              admit: (item) {
                accepted.add(item);
                return true;
              },
            )
            ..add(
              const LiveDanmakuMessage(
                identity: 1,
                receivedAtUs: 0,
                text: '[x]',
                emotes: [LiveEmoteDescriptor('[x]', 'x', 12, 12)],
              ),
            )
            ..process(running: true, fontSize: 20);
      expect(queue.runningTasks, 1);
      now = 300001;
      queue.process(running: true, fontSize: 20);
      expect(accepted, hasLength(1));
      expect(queue.runningTasks, 1);
      expect(queue.reservedBytes, greaterThan(0));
      pending.complete(null);
      await Future<void>.delayed(Duration.zero);
      queue.process(running: true, fontSize: 20);
      expect(queue.runningTasks, 0);
      expect(queue.reservedBytes, 0);
      expect(accepted, hasLength(1));
      queue.dispose();
    },
  );
  test(
    'pause ages candidates while clear isolates in-flight resources',
    () async {
      var now = 0;
      final pending = Completer<ui.Image?>();
      var count = 0;
      final queue =
          LiveDanmakuQueue<void>(
            nowUs: () => now,
            loadImage: (_) => pending.future,
            wake: () {},
            admit: (_) {
              count++;
              return true;
            },
          )..add(
            const LiveDanmakuMessage(identity: 1, receivedAtUs: 0, text: 'one'),
          );
      now = 1000001;
      queue.process(running: false, fontSize: 20);
      expect(queue.candidateCount, 0);
      queue
        ..add(
          LiveDanmakuMessage(
            identity: 2,
            receivedAtUs: now,
            text: '[x]',
            emotes: const [LiveEmoteDescriptor('[x]', 'x', 12, 12)],
          ),
        )
        ..process(running: true, fontSize: 20)
        ..clear();
      expect(queue.runningTasks, 1);
      pending.complete(null);
      await Future<void>.delayed(Duration.zero);
      expect(queue.runningTasks, 0);
      expect(count, 0);
      queue.dispose();
    },
  );
}
