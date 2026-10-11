import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_handoff.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/video_output_handoff.dart';

void main() {
  testWidgets('bridge and live Texture share Flutter scaling across layouts', (
    tester,
  ) async {
    final widgetPlayer = _WidgetPlayer();
    final controller = _VideoController(widgetPlayer);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xFF42A5F5), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final snapshot = picture.toImageSync(16, 9);
    picture.dispose();
    final frame = Completer<bool>();
    final handoff = VideoOutputHandoff(
      waitForProtectedFrame: () async => true,
      capture: () async => snapshot.clone(),
      waitForPaint: () => WidgetsBinding.instance.endOfFrame,
    );
    addTearDown(() async {
      handoff.dispose();
      snapshot.dispose();
      await widgetPlayer.sizes.close();
      controller.id.dispose();
      controller.rect.dispose();
    });
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 3;
    final frameKey = GlobalKey();
    SimpleVideoState? retained;
    Future<void> layout(Size viewport) async {
      tester.view.physicalSize = viewport * 3;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: viewport, devicePixelRatio: 3),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: FittedBox(
              fit: BoxFit.contain,
              child: VideoOutputHandoffView(
                handoff: handoff,
                frameKey: frameKey,
                child: SimpleVideo(controller: controller),
              ),
            ),
          ),
        ),
      );
      final state = tester.state<SimpleVideoState>(find.byType(SimpleVideo));
      retained ??= state;
      expect(state, same(retained));
      final texture = tester.widget<Texture>(find.byType(Texture));
      expect(texture.textureId, 1);
      expect(
        texture.freeze,
        isFalse,
        reason: 'Must continue acquiring frames beneath the snapshot',
      );
      expect(tester.getSize(find.byType(Texture)), const Size(640, 360));
      expect(tester.getSize(find.byType(FittedBox)), viewport);
      expect(tester.takeException(), isNull);
    }

    await layout(const Size(385.3333333333333, 216.75));
    final run = handoff.run(
      isCurrent: () => true,
      canStart: () => true,
      submit: (_) => frame.future,
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(RawImage), findsOneWidget);
    for (final size in [
      const Size(500, 300),
      const Size(836.6666666666666, 385.3333333333333),
      const Size(600, 350),
    ]) {
      await layout(size);
      expect(find.byType(RawImage), findsOneWidget);
      expect(
        tester.getSize(find.byType(RawImage)),
        tester.getSize(find.byType(Texture)),
      );
    }
    frame.complete(true);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(await run, isTrue);
    expect(find.byType(RawImage), findsNothing);
    await layout(const Size(385.3333333333333, 216.75));
    await tester.pumpWidget(const SizedBox());
  });
}

class _WidgetPlayer implements Player {
  final sizes = StreamController<(int, int)>.broadcast(sync: true);
  @override
  final state = PlayerState(width: 1920, height: 1080, playing: true);
  @override
  late final stream = _WidgetStreams(sizes.stream);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WidgetStreams implements PlayerStream {
  _WidgetStreams(this.size);
  @override
  final Stream<(int, int)> size;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _VideoController implements VideoController {
  _VideoController(this.player);
  @override
  final Player player;
  @override
  final id = ValueNotifier<int?>(1);
  @override
  final rect = ValueNotifier<Rect?>(const Rect.fromLTWH(0, 0, 1920, 1080));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
