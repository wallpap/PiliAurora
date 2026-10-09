import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/plugin/pl_player/utils/android_video_output.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_resizer.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_size.dart';

const landscape = (width: 1920, height: 1080);
const portrait = (width: 1080, height: 608);
const intermediate = (width: 1280, height: 720);
const delay = Duration(milliseconds: 250);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.alexmercerind/media_kit_video');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late VideoOutputResizer resizer;
  late _Player player;
  late List<VideoOutputSize> surfaces;
  late List<VideoOutputSize> commits;
  late List<Object> errors;
  late Future<void> Function(VideoOutputSize) resizeSurface;
  VideoOutputSize? surface;

  setUp(() {
    player = _Player();
    surfaces = [];
    commits = [];
    errors = [];
    surface = null;
    resizeSurface = (_) async {};
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      final size = (
        width: int.parse(args['width'] as String),
        height: int.parse(args['height'] as String),
      );
      surfaces.add(size);
      surface = size;
      await resizeSurface(size);
      return null;
    });
    player.onSize = (size) {
      // 真实 helper 的通道和 mpv 通知必须描述同一个 buffer。
      expectSync(size, surface);
      commits.add(size);
    };
    resizer = VideoOutputResizer(
      apply: (size, isCurrent) => setAndroidVideoOutputSize(
        player: player,
        size: size,
        isCurrent: isCurrent,
      ),
      onError: (_, error, _) => errors.add(error),
    );
  });
  tearDown(() {
    resizer.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'paused landscape portrait landscape retains the existing buffer',
    (tester) async {
      resizer.request(landscape);
      await tester.pump(delay);
      expect(errors, isEmpty);
      expect(surfaces, [landscape]);
      expect(commits, [landscape]);
      resizer
        ..setEnabled(false)
        ..request(portrait);
      await tester.pump(delay);
      resizer.request(landscape);
      await tester.pump(delay);
      expect(surfaces, [landscape]);
      expect(commits, [landscape]);
      expect(resizer.applied, landscape);
      resizer.setEnabled(true);
      await tester.pump(delay);
      expect(commits, [landscape]);
    },
  );

  testWidgets('resume submits only the final paused viewport', (tester) async {
    resizer
      ..setEnabled(false)
      ..request(landscape);
    await tester.pump(delay);
    resizer
      ..request(intermediate)
      ..request(portrait);
    await tester.pump(delay);
    expect(surfaces, isEmpty);
    expect(resizer.applied, isNull);
    resizer.setEnabled(true);
    await tester.pump(delay);
    expect(commits, [portrait]);
    expect(resizer.applied, portrait);
  });

  testWidgets('pausing cancels a resize not yet dispatched', (tester) async {
    resizer.request(landscape);
    await tester.pump(delay);
    resizer.request(portrait);
    await tester.pump(const Duration(milliseconds: 125));
    resizer.setEnabled(false);
    await tester.pump(delay);
    expect(commits, [landscape]);
  });

  testWidgets(
    'returning to an applied size during a resize still restores it',
    (tester) async {
      resizer.request(landscape);
      await tester.pump(delay);
      final gate = Completer<void>();
      resizeSurface = (size) =>
          size == portrait ? gate.future : Future<void>.value();
      resizer.request(portrait);
      await tester.pump(delay);
      expect(surfaces, [landscape, portrait]);
      expect(resizer.applied, landscape);
      resizer.request(landscape);
      await tester.pump(delay);
      expect(surfaces, [landscape, portrait]);
      gate.complete();
      await tester.pump();
      expect(commits, [landscape, portrait, landscape]);
      expect(resizer.applied, landscape);
      expect(errors, isEmpty);
    },
  );

  testWidgets(
    'new viewport cannot invalidate mpv synchronization already in progress',
    (tester) async {
      final gate = Completer<void>();
      resizeSurface = (_) => gate.future;
      resizer.request(portrait);
      await tester.pump(delay);
      resizer
        ..request(landscape)
        ..setEnabled(false);
      gate.complete();
      await tester.pump();
      expect(commits, [portrait]);
      expect(resizer.applied, portrait);
      expect(resizer.target, landscape);
      await tester.pump(delay);
      expect(surfaces, [portrait]);
      resizeSurface = (_) async {};
      resizer.setEnabled(true);
      await tester.pump(delay);
      expect(commits, [portrait, landscape]);
    },
  );

  testWidgets(
    'layout changes coalesce without postponing an identical target',
    (tester) async {
      resizer.request(landscape);
      await tester.pump(const Duration(milliseconds: 125));
      resizer.request(portrait);
      await tester.pump(const Duration(milliseconds: 125));
      resizer.request(portrait);
      await tester.pump(const Duration(milliseconds: 125));
      expect(commits, [portrait]);
      resizer.request(portrait);
      await tester.pump(delay);
      expect(commits, [portrait]);
    },
  );

  testWidgets(
    'rotation frames lasting over 100ms do not resize intermediate outputs',
    (tester) async {
      resizer.request(landscape);
      await tester.pump(delay);
      resizer.request(intermediate);
      await tester.pump(const Duration(milliseconds: 150));
      expect(surfaces, [landscape]);
      resizer.request(portrait);
      await tester.pump(const Duration(milliseconds: 150));
      expect(surfaces, [landscape]);
      await tester.pump(const Duration(milliseconds: 100));
      expect(surfaces, [landscape, portrait]);
      expect(commits, [landscape, portrait]);
    },
  );

  testWidgets('unchanged rounded target waits for the last layout event', (
    tester,
  ) async {
    resizer.request(landscape);
    await tester.pump(const Duration(milliseconds: 200));
    resizer.defer();
    await tester.pump(const Duration(milliseconds: 200));
    resizer.defer();
    await tester.pump(const Duration(milliseconds: 249));
    expect(surfaces, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(surfaces, [landscape]);
    expect(resizer.pending, isFalse);
  });

  testWidgets('only the latest waiting target follows an in-flight request', (
    tester,
  ) async {
    final gate = Completer<void>();
    resizeSurface = (size) =>
        size == landscape ? gate.future : Future<void>.value();
    resizer.request(landscape);
    await tester.pump(delay);
    resizer.request(intermediate);
    await tester.pump(delay);
    resizer.request(portrait);
    await tester.pump(delay);
    expect(surfaces, [landscape]);
    gate.complete();
    await tester.pump();
    expect(commits, [landscape, portrait]);
  });

  testWidgets(
    'a failed resize is not cached and an identical request can retry',
    (tester) async {
      resizeSurface = (_) =>
          Future<void>.error(PlatformException(code: 'resize-failed'));
      resizer.request(portrait);
      await tester.pump(delay);
      expect(resizer.applied, isNull);
      expect(errors, hasLength(1));
      expect(commits, isEmpty);
      resizeSurface = (_) async {};
      resizer.request(portrait);
      await tester.pump(delay);
      expect(resizer.applied, portrait);
      expect(commits, [portrait]);
    },
  );

  testWidgets(
    'returning to the previous size after a partial failure resynchronizes',
    (tester) async {
      resizer.request(landscape);
      await tester.pump(delay);
      resizeSurface = (_) => Future<void>.error(
        PlatformException(code: 'resize-after-buffer-change'),
      );
      resizer.request(portrait);
      await tester.pump(delay);
      expect(surface, portrait);
      expect(resizer.applied, isNull);
      expect(errors, hasLength(1));
      resizeSurface = (_) async {};
      resizer.request(landscape);
      await tester.pump(delay);
      expect(surfaces, [landscape, portrait, landscape]);
      expect(commits, [landscape, landscape]);
      expect(resizer.applied, landscape);
    },
  );

  testWidgets('a refused submission is not cached', (tester) async {
    player.current.clear();
    resizer.request(portrait);
    await tester.pump(delay);
    expect(resizer.applied, isNull);
    expect(surfaces, isEmpty);
    player.current.add(const Media('file:///next.mp4'));
    resizer.request(portrait);
    await tester.pump(delay);
    expect(commits, [portrait]);
  });

  testWidgets(
    'a new surface requires resubmission even at the same resolution',
    (tester) async {
      resizer.request(landscape);
      await tester.pump(delay);
      resizer.invalidate();
      expect(resizer.applied, isNull);
      expect(resizer.target, isNull);
      resizer.request(landscape);
      await tester.pump(delay);
      expect(commits, [landscape, landscape]);
    },
  );

  testWidgets(
    'surface invalidation prevents the old resize from entering mpv',
    (tester) async {
      final gate = Completer<void>();
      resizeSurface = (size) =>
          size == portrait ? gate.future : Future<void>.value();
      resizer.request(portrait);
      await tester.pump(delay);
      resizer
        ..invalidate()
        ..request(landscape);
      await tester.pump(delay);
      gate.complete();
      await tester.pump();
      expect(surfaces, [portrait, landscape]);
      expect(commits, [landscape]);
      expect(resizer.applied, landscape);
    },
  );

  testWidgets(
    'dispose cancels pending work and invalidates an in-flight response',
    (tester) async {
      final gate = Completer<void>();
      resizeSurface = (_) => gate.future;
      resizer.request(portrait);
      await tester.pump(delay);
      resizer
        ..request(landscape)
        ..dispose();
      gate.complete();
      await tester.pump();
      resizer
        ..request(intermediate)
        ..setEnabled(true);
      await tester.pump(delay);
      expect(surfaces, [portrait]);
      expect(commits, isEmpty);
      expect(resizer.applied, isNull);
    },
  );
}

class _Player implements NativePlayer {
  @override
  bool disposed = false;
  @override
  final List<Media> current = [const Media('file:///test.mp4')];
  @override
  int get handle => 42;
  late void Function(VideoOutputSize) onSize;
  @override
  void setOption(String opt, String value) {
    if (opt == 'android-surface-size') {
      final dimensions = value.split('x').map(int.parse).toList();
      onSize((width: dimensions[0], height: dimensions[1]));
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
