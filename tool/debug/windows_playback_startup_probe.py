#!/usr/bin/env python3
"""Exercise the Windows viewport size caller with delayed raster receipts.

The fixture uses the production _applyVideoOutputSize method and handoff/barrier
classes. GPU rendering and the video controller channel are replaced by fakes.
"""
from pathlib import Path
import subprocess

from windows_texture_frame_probe import method


HEADER = r"""
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_handoff.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_paint_barrier.dart';

class FakePlayer {
  final current = <Object>[Object()];
  bool disposed = false;
  final state = (width: 3840, height: 2160);
}
class FakeController {
  FakeController(VideoOutputSize size)
    : configuration = VideoControllerConfiguration(width: size.width, height: size.height),
      rect = ValueNotifier(ui.Rect.fromLTWH(0, 0, size.width.toDouble(), size.height.toDouble()));
  final VideoControllerConfiguration configuration;
  final player = FakePlayer();
  final ValueNotifier<ui.Rect?> rect;
  int submissions = 0;
  Future<void> setSize({int? width, int? height}) async {
    submissions++;
    rect.value = ui.Rect.fromLTWH(0, 0, width!.toDouble(), height!.toDouble());
  }
}
class FakeResizer {
  FakeResizer(this.target);
  final VideoOutputSize target;
  final VideoOutputSize? applied = null;
  int get generation => 1;
}
class FixtureViewport {
  FixtureViewport(VideoOutputSize output, VideoOutputSize target, this._videoOutputHandoff)
    : videoController = FakeController(output), _videoOutputResizer = FakeResizer(target);
  bool mounted = true;
  bool get _limitWindowsVideoOutput => true;
  final FakeController videoController;
  final FakeResizer _videoOutputResizer;
  final VideoOutputHandoff _videoOutputHandoff;
  void _logVideoOutputResize(String event, VideoOutputSize size, {int? generation, bool? accepted}) {}
  CALLER
}

ui.FrameTiming receipt(int frame) => ui.FrameTiming(
  vsyncStart: 0, buildStart: 1, buildFinish: 2, rasterStart: 3,
  rasterFinish: 4, rasterFinishWallTime: 5, frameNumber: frame,
);
"""

MAIN = r"""
void main() {
  for (final size in [(width: 2560, height: 1440), (width: 1920, height: 1080)]) {
    testWidgets('ready $size output remains live without batched timing reports', (tester) async {
      final barrier = VideoOutputPaintBarrier(frameNumber: () => 40);
      var captures = 0;
      final handoff = VideoOutputHandoff(
        capture: () async {
          captures++;
          final picture = ui.PictureRecorder();
          ui.Canvas(picture).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
          final recording = picture.endRecording();
          final image = recording.toImageSync(2, 2);
          recording.dispose();
          return image;
        },
        waitForPaint: () async {},
        waitForProtectedFrame: barrier.wait,
      );
      addTearDown(barrier.dispose);
      addTearDown(handoff.dispose);
      final view = FixtureViewport(size, size, handoff);
      bool? completed;
      final run = view._applyVideoOutputSize(size, () => true).then((value) => completed = value);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final frozen = handoff.image != null;
      final beforeReceipt = completed;
      tester.platformDispatcher.onReportTimings?.call([receipt(40)]);
      await tester.pump();
      await run;
      print('PROBE output=$size frozenAt500ms=$frozen acceptedBeforeReceipt=$beforeReceipt captures=$captures');
      expect(frozen, isFalse, reason: 'Pinning an unchanged texture must not freeze playback');
      expect(beforeReceipt, isTrue);
      expect(captures, 0);
      expect(view.videoController.submissions, 1);
    });
  }
  testWidgets('real size changes still wait for the protected raster frame', (tester) async {
    final barrier = VideoOutputPaintBarrier(frameNumber: () => 40);
    final handoff = VideoOutputHandoff(
      capture: () async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
        final picture = recorder.endRecording();
        final image = picture.toImageSync(2, 2);
        picture.dispose();
        return image;
      },
      waitForPaint: () async {},
      waitForProtectedFrame: barrier.wait,
    );
    addTearDown(barrier.dispose);
    addTearDown(handoff.dispose);
    const target = (width: 2560, height: 1440);
    final view = FixtureViewport((width: 3840, height: 2160), target, handoff);
    final run = view._applyVideoOutputSize(target, () => true);
    await tester.pump();
    expect(handoff.image, isNotNull);
    expect(view.videoController.submissions, 0);
    tester.platformDispatcher.onReportTimings?.call([receipt(39)]);
    await tester.pump();
    expect(view.videoController.submissions, 0);
    tester.platformDispatcher.onReportTimings?.call([receipt(40)]);
    await tester.pump();
    expect(await run, isTrue);
    expect(view.videoController.submissions, 1);
    expect(handoff.image, isNull);
  });
}
"""


def main():
    root = Path(__file__).resolve().parents[2]
    source = (root / 'lib/plugin/pl_player/view/view.dart').read_text(encoding='utf-8')
    caller = method(source, 'Future<bool> _applyVideoOutputSize(')
    fixture = root / 'build/windows-playback-diagnosis/playback_startup_probe_test.dart'
    fixture.parent.mkdir(parents=True, exist_ok=True)
    fixture.write_text(HEADER.replace('CALLER', caller) + MAIN, encoding='utf-8')
    raise SystemExit(subprocess.run([
        'fvm.bat', 'flutter', 'test', '--no-pub', str(fixture), '--reporter', 'expanded',
    ], cwd=root).returncode)


if __name__ == '__main__':
    main()
