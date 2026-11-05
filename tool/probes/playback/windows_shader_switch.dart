import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/models/common/super_resolution_type.dart';
import 'package:pili_aurora/plugin/pl_player/playback/shader_updates.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_playback_runtime.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/plugin/pl_player/utils/playback_load_queue.dart';
import 'package:pili_aurora/services/diagnostics/process_metrics.dart';
import 'package:pili_aurora/utils/path_utils.dart';

/// 使用实际 Flutter、mpv、ANGLE、纹理通道验证超分切换；只播放指定本地文件。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows) throw UnsupportedError('Windows probe');
  const root = String.fromEnvironment('SHADER_PROBE_ROOT');
  const media = String.fromEnvironment('SHADER_PROBE_VIDEO');
  final output = Directory(const String.fromEnvironment('SHADER_PROBE_OUTPUT'));
  const resetEnabled = bool.fromEnvironment(
    'SHADER_PROBE_RESET',
    defaultValue: true,
  );
  const startMs = int.fromEnvironment(
    'SHADER_PROBE_START_MS',
    defaultValue: 4300,
  );
  if (!File(media).existsSync()) throw ArgumentError('Local media is required');
  await output.create(recursive: true);
  MediaKit.ensureInitialized();
  const useSession = bool.fromEnvironment('SHADER_PROBE_SESSION');
  final runtime = useSession
      ? NativePlaybackRuntime(
          configuration: PlaybackRuntimeConfig(
            playerOptions: const {
              'ao': 'null',
              'gpu-dumb-mode': 'no',
              'video-sync': 'audio',
              'cache': 'yes',
              'cache-secs': '16',
              'demuxer-max-bytes': '4194304',
              'demuxer-max-back-bytes': '4194304',
            },
            hardwareAccelerationEnabled: true,
            hardwareDecoder: 'd3d11va',
            width: 1280,
            height: 720,
          ),
          diagnosticsExtra: () => const {},
        )
      : null;
  final session = runtime == null ? null : PlaybackSession(runtime: runtime);
  final owner = session?.attach();
  if (owner != null) {
    runApp(const MaterialApp(home: ColoredBox(color: Colors.black)));
    final attach = Timer.periodic(const Duration(milliseconds: 20), (_) {
      final video = runtime!.videoController;
      if (video != null) {
        runApp(
          MaterialApp(
            home: Center(child: SimpleVideo(controller: video)),
          ),
        );
      }
    });
    try {
      final loaded = await owner.load(
        PlaybackPlan(
          contentKey: 'shader-fixture',
          source: PlaybackSourceSnapshot.fromDataSource(
            NetworkSource(videoSource: media, audioSource: null),
          ),
          timeline: const PlaybackTimeline(
            kind: PlaybackTimelineKind.onDemand,
            seekPolicy: PlaybackSeekPolicy.allowed,
          ),
          configuration: PlaybackConfiguration(),
        ),
        start: PlaybackStartPolicy.play,
      );
      if (loaded.outcome != LoadOutcome.ready) {
        throw StateError('Session load failed');
      }
    } finally {
      attach.cancel();
    }
  }
  final player =
      runtime?.player ??
      await Player.create(
        configuration: const PlayerConfiguration(
          logLevel: .warn,
          options: {
            'ao': 'null',
            'gpu-dumb-mode': 'no',
            'video-sync': 'audio',
            'cache': 'yes',
            'cache-secs': '16',
            'demuxer-max-bytes': '4194304',
            'demuxer-max-back-bytes': '4194304',
          },
        ),
      );
  final video =
      runtime?.videoController ??
      await VideoController.create(
        player,
        configuration: const VideoControllerConfiguration(
          width: 1280,
          height: 720,
          hwdec: 'd3d11va',
        ),
      );
  final boundary = GlobalKey();
  runApp(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: RepaintBoundary(
            key: boundary,
            child: SizedBox(
              width: 640,
              height: 360,
              child: SimpleVideo(controller: video, aspectRatio: 16 / 9),
            ),
          ),
        ),
      ),
    ),
  );
  final updates = PlaybackLoadQueue();
  final metrics = ProcessMetrics();
  final results = <Map<String, Object?>>[];
  final originalHandle = player.handle;
  final decoderErrors = <String>[];
  final logSubscription = player.stream.log.listen((log) {
    if ((log.prefix == 'vd' || log.prefix == 'ffmpeg/video') &&
        const {'warn', 'error', 'fatal'}.contains(log.level)) {
      decoderErrors.add('${log.prefix}: ${log.text.trim()}');
    }
  });
  int resets = 0;

  void check(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  Future<void> waitFor(bool Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Native frame');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<void> select(SuperResolutionType mode, {int seconds = 4}) async {
    final beforeId = video.id.value;
    final beforeAudio = double.tryParse(player.getProperty('audio-pts'));
    final beforePosition = double.parse(player.getProperty('time-pos'));
    final wasPlaying = player.state.playing;
    final beforeErrors = decoderErrors.length;
    final beforeResets = resets;
    final names = mode == SuperResolutionType.efficiency
        ? Assets.mpvAnime4KShadersLite
        : Assets.mpvAnime4KShaders;
    final watch = Stopwatch()..start();
    await updates.run((isCurrent) async {
      final paths = mode == SuperResolutionType.disable
          ? ''
          : PathUtils.buildShadersAbsolutePath('$root/assets/shaders', names);
      if (!isCurrent()) return;
      if (owner != null) {
        final beforeLoad = session!.loadId;
        final changed = await owner.setShader(
          paths.isEmpty ? [] : paths.split(';'),
        );
        check(
          changed.outcome == CommandOutcome.applied,
          'Session shader failed',
        );
        if (session.loadId != beforeLoad) resets++;
      } else {
        await applyShaderList(
          paths,
          command: player.command,
          resetRenderer: resetEnabled
              ? () async {
                  resets++;
                  await video.resetRenderer();
                }
              : null,
        );
      }
    });
    if (resets > beforeResets) await waitFor(() => video.id.value != beforeId);
    await Future<void>.delayed(Duration(seconds: seconds));
    check(
      decoderErrors.length == beforeErrors,
      'Decode errors during shader switch: '
      '${decoderErrors.skip(beforeErrors).join('; ')}',
    );
    check(player.handle == originalHandle, 'Player was replaced');
    check(
      player.getProperty('hwdec-current') == 'd3d11va',
      'Hardware decoder changed',
    );
    check(player.state.playing == wasPlaying, 'Playback intent changed');
    final actual = player.getProperty('glsl-shaders');
    check(
      (mode == SuperResolutionType.disable) == actual.isEmpty,
      'Shader list mismatch',
    );
    final afterAudio = double.tryParse(player.getProperty('audio-pts'));
    check(beforeAudio != null && afterAudio != null, 'No audio timeline');
    if (wasPlaying) {
      check(afterAudio! > beforeAudio!, 'Audio timeline stopped');
    } else {
      check((afterAudio! - beforeAudio!).abs() < 0.5, 'Paused audio moved');
    }
    await WidgetsBinding.instance.endOfFrame;
    final render =
        boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 1);
    final pixels = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    var low = 255, high = 0;
    for (var y = 32; y < image.height - 32; y += 4) {
      for (var x = 32; x < image.width - 32; x += 4) {
        final value = pixels.getUint8((y * image.width + x) * 4);
        if (value < low) low = value;
        if (value > high) high = value;
      }
    }
    image.dispose();
    check(high - low > 16, 'Blank Flutter video texture');
    final row = <String, Object?>{
      'session': useSession,
      'mpv': player.getProperty('mpv-version'),
      'mode': mode.name,
      'playing': player.state.playing,
      'privateMiB': (metrics.sample()['privateBytes'] as int) / 1048576,
      'resets': resets,
      'textureChanged': video.id.value != beforeId,
      'positionBefore': beforePosition,
      'positionAfter': double.parse(player.getProperty('time-pos')),
      'audioBefore': beforeAudio,
      'audioAfter': afterAudio,
      'elapsedMs': watch.elapsedMilliseconds,
      'pixelRange': high - low,
    };
    results.add(row);
    stdout.writeln(jsonEncode(row));
    await File('${output.path}/results.json')
        .writeAsString(jsonEncode(results));
  }

  try {
    if (owner == null) await player.open(const Media(media));
    await waitFor(() => player.state.width > 0 && video.rect.value != null);
    if (startMs > 0) {
      if (owner != null) {
        await owner.seek(const Duration(milliseconds: startMs));
      } else {
        await player.seek(const Duration(milliseconds: startMs));
      }
    }
    await Future<void>.delayed(const Duration(seconds: 3));
    await select(SuperResolutionType.disable);
    await select(SuperResolutionType.efficiency);
    await select(SuperResolutionType.quality);
    await select(SuperResolutionType.efficiency);
    await select(SuperResolutionType.disable, seconds: 12);
    final baseline = results.first['privateMiB'] as double;
    final disabled = results.last['privateMiB'] as double;
    check(disabled < baseline + 128, 'Disabled shader resources retained');
    if (owner != null) {
      await owner.setPlaying(false);
    } else {
      await player.pause();
    }
    await select(SuperResolutionType.efficiency);
    await select(SuperResolutionType.disable, seconds: 12);
    if (owner != null) {
      await owner.setPlaying(true);
    } else {
      await player.play();
    }
    await select(SuperResolutionType.disable, seconds: 2);
    updates.dispose();
    await updates.drained;
    if (owner != null) {
      owner.close();
      await session!.shutdown();
    } else {
      await player.dispose();
    }
    await logSubscription.cancel();
    await File('${output.path}/PASS')
        .writeAsString('Shader memory, texture, pause and audio checks passed');
    exit(0);
  } catch (error, stack) {
    await File('${output.path}/FAIL').writeAsString('$error\n$stack');
    updates.dispose();
    await updates.drained;
    if (owner != null) {
      owner.close();
      await session!.shutdown();
    } else {
      await player.dispose();
    }
    await logSubscription.cancel();
    exit(1);
  }
}
