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
    'small-window state restores native output once, not per layout',
    (tester) async {
      final machine = VideoOutputStateMachine();
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

  testWidgets('rapid state events only submit the final output', (
    tester,
  ) async {
    final machine = VideoOutputStateMachine();
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

  test(
    'prioritizes PiP, fullscreen, maximized and restored window',
    () {
      final machine = VideoOutputStateMachine();
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

  test('restores source output when returning to a resizable window', () {
    final machine = VideoOutputStateMachine()
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
  });

  test('ignores viewport changes after state configuration', () {
    final machine = VideoOutputStateMachine()
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
    expect(target(machine, width: 800, height: 450), (width: 800, height: 450));
    machine.acknowledgeResize();
    expect(target(machine), isNull);
  });

  test('small-window output is independent of viewport and DPR', () {
    final machine = VideoOutputStateMachine()
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
    final machine = VideoOutputStateMachine()
      ..transition(isFullScreen: true, isPipMode: false);
    expect(target(machine, width: 2560, height: 1440, dpr: 2), (
      width: 1920,
      height: 1080,
    ));
  });

  test('missing source or layout does not consume pending configuration', () {
    final machine = VideoOutputStateMachine();
    expect(target(machine), isNull);
    machine.transition(
      isFullScreen: false,
      isPipMode: false,
      isMaximized: true,
    );
    expect(target(machine, source: null), isNull);
    expect(target(machine, source: (width: 0, height: 0)), isNull);
    expect(target(machine, width: 0), isNull);
    expect(machine.resizePending, isTrue);
    expect(target(machine), (width: 960, height: 540));
    machine.acknowledgeResize();
    expect(machine.resizePending, isFalse);
  });

  test('source lifecycle is independent of state transitions', () {
    final machine = VideoOutputStateMachine();
    expect(machine.resizePending, isTrue);
    machine.acknowledgeResize();
    expect(machine.resizePending, isFalse);
    machine.sourceChanged();
    expect(machine.resizePending, isTrue);
    machine.acknowledgeResize();
    expect(machine.resizePending, isFalse);
  });
}
