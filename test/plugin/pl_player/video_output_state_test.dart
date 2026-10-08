import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_resizer.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_size.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_state.dart';

VideoOutputSize? target(
  VideoOutputStateMachine machine, {
  VideoOutputSize? source = (width: 1920, height: 1080),
  double width = 960,
  double height = 540,
  double dpr = 1,
}) => machine.targetSize(
  source: source,
  logicalWidth: width,
  logicalHeight: height,
  devicePixelRatio: dpr,
);

void main() {
  testWidgets(
    'Windows small window restores native output once, not per layout',
    (tester) async {
      final machine = VideoOutputStateMachine(VideoOutputPlatform.windows);
      final applied = <VideoOutputSize>[];
      final resizer = VideoOutputResizer(
        settleDelay: const Duration(milliseconds: 100),
        apply: (size, _) async {
          applied.add(size);
          return true;
        },
        onError: (_, error, _) => fail('$error'),
      );
      addTearDown(resizer.dispose);
      void sync({
        required bool maximized,
        double width = 960,
        double height = 540,
      }) {
        machine.transition(
          isFullScreen: false,
          isPipMode: false,
          isMaximized: maximized,
        );
        final size = target(machine, width: width, height: height);
        if (size != null) {
          resizer.request(size);
          machine.acknowledgeResize();
        }
      }

      sync(maximized: true);
      await tester.pump(const Duration(milliseconds: 100));
      sync(maximized: false, width: 400, height: 225);
      await tester.pump(const Duration(milliseconds: 100));
      sync(maximized: false, width: 800, height: 450);
      sync(maximized: false, width: 500, height: 281);
      await tester.pump(const Duration(seconds: 1));
      expect(applied, [(width: 960, height: 540), (width: 1920, height: 1080)]);
    },
  );

  testWidgets('rapid Windows state events only submit the final output', (
    tester,
  ) async {
    final machine = VideoOutputStateMachine(VideoOutputPlatform.windows);
    final applied = <VideoOutputSize>[];
    final resizer = VideoOutputResizer(
      settleDelay: const Duration(milliseconds: 100),
      apply: (size, _) async {
        applied.add(size);
        return true;
      },
      onError: (_, error, _) => fail('$error'),
    );
    addTearDown(resizer.dispose);
    for (final event in [(false, true), (true, true), (false, false)]) {
      machine.transition(
        isFullScreen: event.$1,
        isPipMode: false,
        isMaximized: event.$2,
      );
      resizer.request(target(machine)!);
      machine.acknowledgeResize();
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(applied, [(width: 1920, height: 1080)]);
  });

  testWidgets('Android paused state transitions queue only the final resize', (
    tester,
  ) async {
    final machine = VideoOutputStateMachine(VideoOutputPlatform.android);
    final applied = <VideoOutputSize>[];
    final resizer = VideoOutputResizer(
      enabled: false,
      apply: (size, _) async {
        applied.add(size);
        return true;
      },
      onError: (_, error, _) => fail('$error'),
    );
    addTearDown(resizer.dispose);
    machine.transition(isFullScreen: true, isPipMode: false, isLandscape: true);
    resizer.request(target(machine)!);
    machine
      ..acknowledgeResize()
      ..transition(isFullScreen: true, isPipMode: true);
    resizer.request(target(machine, width: 320, height: 200)!);
    machine.acknowledgeResize();
    await tester.pump(const Duration(seconds: 1));
    expect(applied, isEmpty);
    resizer.setEnabled(true);
    await tester.pump(const Duration(milliseconds: 250));
    expect(applied, [(width: 320, height: 180)]);
  });

  test('Android defaults, fullscreen and PiP have finite transitions', () {
    final machine = VideoOutputStateMachine(VideoOutputPlatform.android);
    expect(
      machine.transition(isFullScreen: false, isPipMode: false),
      VideoOutputState.defaultPlayer,
    );
    expect(
      machine.transition(isFullScreen: true, isPipMode: false),
      VideoOutputState.fullscreen,
    );
    expect(
      machine.transition(isFullScreen: true, isPipMode: true),
      VideoOutputState.smallWindow,
    );
    expect(machine.transition(isFullScreen: true, isPipMode: true), isNull);
    expect(
      machine.transition(isFullScreen: false, isPipMode: false),
      VideoOutputState.defaultPlayer,
    );
  });

  test(
    'Windows prioritizes PiP, fullscreen, maximized and restored window',
    () {
      final machine = VideoOutputStateMachine(VideoOutputPlatform.windows);
      expect(
        machine.transition(isFullScreen: false, isPipMode: false),
        VideoOutputState.smallWindow,
      );
      expect(
        machine.transition(
          isFullScreen: false,
          isPipMode: false,
          isMaximized: true,
        ),
        VideoOutputState.defaultPlayer,
      );
      expect(
        machine.transition(
          isFullScreen: true,
          isPipMode: false,
          isMaximized: true,
        ),
        VideoOutputState.fullscreen,
      );
      expect(
        machine.transition(
          isFullScreen: true,
          isPipMode: true,
          isMaximized: true,
        ),
        VideoOutputState.smallWindow,
      );
      expect(
        machine.transition(isFullScreen: true, isPipMode: false),
        VideoOutputState.fullscreen,
      );
      expect(
        machine.transition(isFullScreen: false, isPipMode: false),
        VideoOutputState.smallWindow,
      );
    },
  );

  test(
    'Windows restores source output on return to a resizable small window',
    () {
      final machine = VideoOutputStateMachine(VideoOutputPlatform.windows)
        ..transition(
          isFullScreen: false,
          isPipMode: false,
          isMaximized: true,
        );
      expect(target(machine), (width: 960, height: 540));
      machine
        ..acknowledgeResize()
        ..transition(
          isFullScreen: true,
          isPipMode: false,
          isMaximized: true,
        );
      expect(target(machine, width: 1920, height: 1080), (
        width: 1920,
        height: 1080,
      ));
      machine
        ..acknowledgeResize()
        ..transition(
          isFullScreen: false,
          isPipMode: false,
          isMaximized: true,
        );
      expect(target(machine), (width: 960, height: 540));
      machine
        ..acknowledgeResize()
        ..transition(isFullScreen: false, isPipMode: false);
      expect(target(machine, width: 400, height: 225), (
        width: 1920,
        height: 1080,
      ));
    },
  );

  for (final platform in VideoOutputPlatform.values) {
    test('$platform ignores viewport changes after state configuration', () {
      final machine = VideoOutputStateMachine(platform)
        ..transition(
          isFullScreen: false,
          isPipMode: false,
          isMaximized: true,
        );
      expect(target(machine), isNotNull);
      machine.acknowledgeResize();
      expect(
        machine.transition(
          isFullScreen: false,
          isPipMode: false,
          isMaximized: true,
        ),
        isNull,
      );
      expect(target(machine, width: 800, height: 450), isNull);
      expect(target(machine, width: 600, height: 338), isNull);
      expect(machine.resizePending, isFalse);
      machine.sourceChanged();
      expect(target(machine, width: 800, height: 450), (
        width: 800,
        height: 450,
      ));
      machine.acknowledgeResize();
      expect(target(machine), isNull);
    });
  }

  test('Windows small-window output is independent of viewport and DPR', () {
    final machine = VideoOutputStateMachine(VideoOutputPlatform.windows)
      ..transition(isFullScreen: false, isPipMode: false);
    expect(target(machine, width: 280, height: 160, dpr: 2), (
      width: 1920,
      height: 1080,
    ));
    machine.acknowledgeResize();
    expect(target(machine, width: 1500, height: 900), isNull);
    machine.sourceChanged();
    expect(target(machine, source: (width: 3840, height: 2160)), (
      width: 3840,
      height: 2160,
    ));
  });

  test('fullscreen works without maximization and never upscales source', () {
    final machine = VideoOutputStateMachine(VideoOutputPlatform.windows)
      ..transition(isFullScreen: true, isPipMode: false);
    expect(target(machine, width: 2560, height: 1440, dpr: 2), (
      width: 1920,
      height: 1080,
    ));
  });

  test('Android rotation reconfigures state, Windows orientation does not', () {
    for (final platform in VideoOutputPlatform.values) {
      final machine = VideoOutputStateMachine(platform)
        ..transition(
          isFullScreen: false,
          isPipMode: false,
          isMaximized: true,
        )
        ..acknowledgeResize();
      final next = machine.transition(
        isFullScreen: false,
        isPipMode: false,
        isMaximized: true,
        isLandscape: true,
      );
      expect(
        next,
        platform == VideoOutputPlatform.android
            ? VideoOutputState.defaultPlayer
            : isNull,
      );
      expect(machine.resizePending, platform == VideoOutputPlatform.android);
    }
  });

  test('Android PiP ignores device rotation and preserves source aspect', () {
    final machine = VideoOutputStateMachine(VideoOutputPlatform.android)
      ..transition(isFullScreen: true, isPipMode: true);
    expect(target(machine, width: 320, height: 200), (width: 320, height: 180));
    machine.acknowledgeResize();
    expect(
      machine.transition(
        isFullScreen: true,
        isPipMode: true,
        isLandscape: true,
      ),
      isNull,
    );
    expect(target(machine), isNull);
    expect(
      machine.transition(
        isFullScreen: true,
        isPipMode: false,
        isLandscape: true,
      ),
      VideoOutputState.fullscreen,
    );
    expect(target(machine), isNotNull);
  });

  test('portrait videos remain excluded only on Android', () {
    for (final platform in VideoOutputPlatform.values) {
      final machine = VideoOutputStateMachine(platform)
        ..transition(isFullScreen: false, isPipMode: false);
      expect(
        target(machine, source: (width: 1080, height: 1920)),
        platform == VideoOutputPlatform.android
            ? isNull
            : (width: 1080, height: 1920),
      );
    }
  });

  test('missing source or layout does not consume pending configuration', () {
    final machine = VideoOutputStateMachine(VideoOutputPlatform.android);
    expect(target(machine), isNull);
    machine.transition(isFullScreen: false, isPipMode: false);
    expect(target(machine, source: null), isNull);
    expect(target(machine, source: (width: 0, height: 0)), isNull);
    expect(target(machine, width: 0), isNull);
    expect(machine.resizePending, isTrue);
    expect(target(machine), (width: 960, height: 540));
    machine.acknowledgeResize();
    expect(machine.resizePending, isFalse);
  });

  test('source lifecycle is independent of state transitions', () {
    final machine = VideoOutputStateMachine(VideoOutputPlatform.android);
    expect(machine.resizePending, isTrue);
    machine.acknowledgeResize();
    expect(machine.resizePending, isFalse);
    machine.sourceChanged();
    expect(machine.resizePending, isTrue);
    machine.acknowledgeResize();
    expect(machine.resizePending, isFalse);
  });
}
