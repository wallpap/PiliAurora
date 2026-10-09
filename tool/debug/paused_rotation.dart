import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/utils/android_video_output.dart';
import 'package:pili_aurora/plugin/pl_player/utils/hardware_video_configuration.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_resizer.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_handoff.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_paint_barrier.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/video_output_handoff.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_size.dart';

/// 只读模拟器中使用的合成视频回归入口，不初始化账号、设置或应用网络请求。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.leanBack);
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
  ]);
  if (const bool.fromEnvironment('CREATE_ROTATION_FIXTURE')) {
    runApp(
      WidgetsApp(
        debugShowCheckedModeBanner: false,
        color: const Color(0xFFFFFFFF),
        home: const ColoredBox(
          color: Color(0xFFFFFFFF),
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: ColoredBox(
                          color: Color.fromARGB(255, 240, 30, 30),
                        ),
                      ),
                      Expanded(
                        child: ColoredBox(
                          color: Color.fromARGB(255, 30, 220, 30),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: ColoredBox(
                          color: Color.fromARGB(255, 30, 30, 240),
                        ),
                      ),
                      Expanded(
                        child: ColoredBox(
                          color: Color.fromARGB(255, 240, 220, 30),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, _, _) => builder(context),
        ),
      ),
    );
    return;
  }
  final player = await Player.create();
  final controller = await VideoController.create(
    player,
    configuration: hardwareVideoConfiguration(enabled: false, configured: 'no'),
  );
  runApp(
    WidgetsApp(
      debugShowCheckedModeBanner: false,
      color: const Color(0xFF000000),
      home: _RotationProbe(controller: controller),
      pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
        settings: settings,
        pageBuilder: (context, _, _) => builder(context),
      ),
    ),
  );
  player.stream.log.listen((event) {
    if (event.level == 'error' || event.level == 'fatal') {
      debugPrint('PILI_PROBE ${event.prefix}: ${event.text}');
    }
  });
  final videoReady = player.stream.videoParams.firstWhere(
    (params) => (params.dw ?? 0) > 0 && (params.dh ?? 0) > 0,
  );
  await player.open(
    const Media(
      'file:///data/user/0/io.github.wallpap.piliaurora.debug/cache/rotation-fixture.mp4',
    ),
  );
  await videoReady.timeout(const Duration(seconds: 20));
  await controller.waitUntilFirstFrameRendered.timeout(
    const Duration(seconds: 20),
  );
  await Future<void>.delayed(const Duration(seconds: 1));
  await player.pause();
  for (final stage in [
    ('landscape-before', DeviceOrientation.landscapeLeft),
    ('portrait', DeviceOrientation.portraitUp),
    ('landscape-after', DeviceOrientation.landscapeLeft),
  ]) {
    await SystemChrome.setPreferredOrientations([stage.$2]);
    await Future<void>.delayed(const Duration(seconds: 3));
    debugPrint(
      'PILI_PROBE size=${player.state.width}x${player.state.height} rect=${controller.rect.value}',
    );
    debugPrint('PILI_ROTATION ${stage.$1} paused=${!player.state.playing}');
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  debugPrint('PILI_ROTATION done');
}

class _RotationProbe extends StatefulWidget {
  const _RotationProbe({required this.controller});
  final VideoController controller;

  @override
  State<_RotationProbe> createState() => _RotationProbeState();
}

class _RotationProbeState extends State<_RotationProbe> {
  late final VideoOutputResizer _resizer;
  late final VideoOutputHandoff _handoff;
  late final VideoOutputPaintBarrier _paintBarrier;
  final _frameKey = GlobalKey();
  Size? _viewport;
  StreamSubscription<bool>? _playing;

  @override
  void initState() {
    super.initState();
    _paintBarrier = VideoOutputPaintBarrier();
    _handoff = VideoOutputHandoff(
      waitForProtectedFrame: _paintBarrier.wait,
      capture: () async {
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return null;
        final frame = _frameKey.currentContext?.findRenderObject();
        if (frame is! RenderRepaintBoundary ||
            !frame.hasSize ||
            frame.size.isEmpty) {
          return null;
        }
        return frame.toImage(
          pixelRatio: math.min(3, 1920 / frame.size.longestSide),
        );
      },
      waitForPaint: () => WidgetsBinding.instance.endOfFrame,
    );
    _resizer = VideoOutputResizer(
      enabled: widget.controller.player.state.playing,
      apply: (size, isCurrent) => _handoff.run(
        isCurrent: isCurrent,
        canStart: () => mounted && widget.controller.player.state.playing,
        submit: (canStart) => setAndroidVideoOutputSize(
          player: widget.controller.player,
          size: size,
          isCurrent: isCurrent,
          canStart: canStart,
          waitForFrame: true,
        ),
      ),
      onError: (_, error, _) =>
          debugPrint('PILI_PROBE resize failed: ${error.runtimeType}'),
    );
    _playing = widget.controller.player.stream.playing.listen(
      _resizer.setEnabled,
    );
    widget.controller.rect.addListener(_outputChanged);
  }

  void _outputChanged() {
    _resizer.invalidate();
    _handoff.invalidate();
    _paintBarrier.cancel();
    unawaited(cancelAndroidSurfaceFrameWait(widget.controller.player));
    setState(() {});
  }

  @override
  void dispose() {
    _resizer.dispose();
    unawaited(cancelAndroidSurfaceFrameWait(widget.controller.player));
    _handoff.dispose();
    _paintBarrier.dispose();
    _playing?.cancel();
    widget.controller.rect.removeListener(_outputChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final controller = widget.controller;
      final viewport = Size(constraints.maxWidth, constraints.maxHeight);
      if (_viewport != viewport) {
        _viewport = viewport;
        _handoff.viewportChanged();
        _resizer.defer();
      }
      final rect = controller.rect.value;
      final size = calculateVideoOutputSize(
        logicalWidth: constraints.maxWidth,
        logicalHeight: constraints.maxHeight,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        sourceWidth: rect?.width.round(),
        sourceHeight: rect?.height.round(),
        preserveSourceAspectRatio: true,
      );
      if (const bool.fromEnvironment(
            'ANDROID_VIDEO_OUTPUT_SIZE',
            defaultValue: true,
          ) &&
          rect != null &&
          !rect.isEmpty &&
          size != null) {
        _resizer.request(size);
      }
      return ColoredBox(
        color: const Color(0xFF000000),
        child: FittedBox(
          fit: BoxFit.contain,
          child: VideoOutputHandoffView(
            handoff: _handoff,
            frameKey: _frameKey,
            child: SimpleVideo(controller: controller),
          ),
        ),
      );
    },
  );
}
