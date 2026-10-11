import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/utils/hardware_video_configuration.dart';
import 'package:pili_aurora/services/android_video_output_limit.dart';

const _textureScaling = bool.fromEnvironment('ANDROID_TEXTURE_SCALING');

/// 独占测试模拟器中的合成视频回归入口，播放本地素材。
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
    configuration: hardwareVideoConfiguration(
      enabled: false,
      configured: 'no',
      androidOutputLimit: () =>
          _textureScaling ? AndroidVideoOutputLimit.detected : null,
    ),
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
  debugPrint(
    'PILI_PROBE policy=fixed-source textureScaling=$_textureScaling',
  );
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

// 与生产 Android 视口一致，旋转改变 Flutter 布局，Surface 保持初始化时的输出尺寸。
class _RotationProbe extends StatelessWidget {
  const _RotationProbe({required this.controller});
  final VideoController controller;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF000000),
    child: FittedBox(
      fit: BoxFit.contain,
      child: SimpleVideo(controller: controller),
    ),
  );
}
