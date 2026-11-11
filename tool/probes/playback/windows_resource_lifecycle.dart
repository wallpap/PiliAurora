import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_playback_runtime.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/plugin/pl_player/playback/shader_updates.dart';
import 'package:pili_aurora/plugin/pl_player/playback/super_resolution_policy.dart';
import 'package:pili_aurora/plugin/pl_player/utils/native_video_options.dart';
import 'package:pili_aurora/services/diagnostics/process_metrics.dart';
import 'package:pili_aurora/services/windows_video_output_limit.dart';
import 'package:pili_aurora/utils/asset_utils.dart';
import 'package:window_manager/window_manager.dart';

import '../windows/process_heap_memory.dart';

/// 离线测量生产会话切源、超分和关闭；不读取应用账号或清理缓存。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows) throw UnsupportedError('Windows probe');
  final configPath = Platform.environment['PILIAURORA_PLAYER_PROBE_CONFIG'];
  if (configPath == null) throw ArgumentError('Explicit config required');
  final config =
      jsonDecode(await File(configPath).readAsString()) as Map<String, dynamic>;
  final output = File(config['output'] as String);
  final cases = (config['cases'] as List).cast<Map<String, dynamic>>();
  for (final entry in cases) {
    if (!File(entry['source'] as String).existsSync()) {
      throw ArgumentError('Local fixture required');
    }
  }
  await output.parent.create(recursive: true);
  MediaKit.ensureInitialized();
  final boundary = GlobalKey();
  final display = ValueNotifier<VideoController?>(null);
  final fullscreenDisplay = ValueNotifier(false);
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: boundary,
            child: ValueListenableBuilder(
              valueListenable: fullscreenDisplay,
              builder: (context, fullscreen, _) => SizedBox(
                width: fullscreen ? double.infinity : 640,
                height: fullscreen ? double.infinity : 360,
                child: ValueListenableBuilder(
                  valueListenable: display,
                  builder: (context, video, _) => video == null
                      ? const ColoredBox(color: Colors.black)
                      : SimpleVideo(controller: video, aspectRatio: 16 / 9),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  final playerOptionOverrides =
      (config['playerOptions'] as Map?)?.cast<String, String>() ??
      const <String, String>{};
  final runtime = NativePlaybackRuntime(
    configuration: PlaybackRuntimeConfig(
      playerOptions: {
        'ao': 'null',
        ...nativeVideoPlayerOptions(),
        ...playerOptionOverrides,
      },
      hardwareAccelerationEnabled: true,
      hardwareDecoder: 'd3d11va',
    ),
    diagnosticsExtra: () => const {},
  );
  final session = PlaybackSession(
    runtime: runtime,
    configurationForPlan: config['sourceShaderPolicy'] == true
        ? (plan) => superResolutionConfigurationForPlan(
            plan,
            display: VideoOutputSizePolicy.physicalDisplaySize(
              WidgetsBinding
                  .instance
                  .platformDispatcher
                  .views
                  .first
                  .display
                  .size,
            ),
          )
        : null,
  );
  final owner = session.attach();
  void attach() => display.value = runtime.videoController;
  runtime.videoControllerListenable.addListener(attach);
  const native = MethodChannel('com.alexmercerind/media_kit_video');
  const gpu = MethodChannel('pili_aurora/windows_gpu');
  final process = ProcessMetrics();
  final heap = ProcessHeapMemory();
  final watch = Stopwatch()..start();
  final rows = <Map<String, Object?>>[];
  final trace = <Map<String, Object?>>[];
  var phase = 'baseline';
  var tracing = false;
  Future<void>? traceTask;
  final report = <String, Object?>{
    'schemaVersion': 1,
    'scope': 'productionSession;localMedia;nullAudioOutput;noCachePurge',
    'outputPolicy': 'sourceSizeCappedToPhysicalDisplayAfterLoad',
    'sourceShaderPolicy': config['sourceShaderPolicy'] == true,
    'rows': rows,
    'trace': trace,
    'passed': false,
  };
  Future<void> save() => output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
  );
  void check(bool okay, String message) {
    if (!okay) throw StateError(message);
  }

  Future<void> record(String stage, {bool tracing = false}) async {
    final player = runtime.player;
    final video = runtime.videoController;
    final stats = await native.invokeMapMethod<String, Object?>(
      'VideoOutputManager.MemoryStats',
    );
    final graphics = await gpu.invokeMapMethod<String, Object?>('sample');
    final row = <String, Object?>{
      'stage': stage,
      'phase': phase,
      'elapsedMs': watch.elapsedMilliseconds,
      'process': process.sample(),
      if (!tracing) 'defaultHeap': heap.sample(),
      'gpu': graphics,
      'native': stats,
      'runtimeId': runtime.runtimeId,
      'loadId': session.loadId,
      'textureId': video?.id.value,
      'outputWidth': video?.rect.value?.width,
      'outputHeight': video?.rect.value?.height,
      if (player != null) ...{
        'sourceWidth': player.state.width,
        'sourceHeight': player.state.height,
        'playing': player.state.playing,
        'positionMs': player.state.position.inMilliseconds,
        'decoder': player.getProperty('hwdec-current'),
        'shaderCount':
            session.currentSnapshot.configuration.applied.shaders.length,
        'nativeShaderCount': player
            .getProperty('glsl-shaders')
            .split(';')
            .where((shader) => shader.contains('Anime4K_'))
            .length,
        if (!tracing) ...{
          'videoParameters': player.getProperty('video-params'),
          'cacheState': player.getProperty('demuxer-cache-state'),
        },
      },
    };
    if (tracing) {
      // 高频采样只保留区分假设的数值，避免报告本身扩大 Dart 工作集。
      final resources = stats?['resources'] as Map?;
      final adapter = (graphics?['adapters'] as List?)?.cast<Map>().where(
        (adapter) => adapter['flutterUi'] == true,
      );
      trace.add({
        'elapsedMs': row['elapsedMs'],
        'phase': phase,
        'process': row['process'],
        'outputWidth': row['outputWidth'],
        'outputHeight': row['outputHeight'],
        'sourceWidth': row['sourceWidth'],
        'sourceHeight': row['sourceHeight'],
        'decoder': row['decoder'],
        'nativeShaderCount': row['nativeShaderCount'],
        'd3dTexture': resources?['d3dTexture'],
        'renderContext': resources?['renderContext'],
        if (adapter?.isNotEmpty == true) 'gpuLocal': adapter!.first['local'],
      });
    } else {
      rows.add(row);
      await save();
    }
  }

  try {
    await gpu.invokeMethod<void>('start');
    await record('baseline');
    if (config['baselineSamples'] == true) {
      await Future<void>.delayed(const Duration(seconds: 3));
      for (var sample = 0; sample < 3; sample++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        await record('baseline.$sample');
      }
    }
    final traceIntervalMs = config['traceIntervalMs'] as int? ?? 0;
    if (traceIntervalMs > 0) {
      tracing = true;
      traceTask = () async {
        while (tracing) {
          await record('transition', tracing: true);
          await Future<void>.delayed(Duration(milliseconds: traceIntervalMs));
        }
      }();
    }
    for (var index = 0; index < cases.length; index++) {
      final entry = cases[index];
      final name = entry['name'] as String;
      phase = '$name.load';
      if (entry['resetBeforeLoad'] == true) {
        final player = runtime.player!;
        await player.stop();
        await applyShaderList(
          player.getProperty('glsl-shaders'),
          command: player.command,
          resetRenderer: runtime.videoController!.resetRenderer,
        );
      }
      final mode = entry['mode'] as String? ?? 'disable';
      final shaders = switch (mode) {
        'disable' => const <String>[],
        'efficiency' => Assets.mpvAnime4KShadersLite,
        'quality' => Assets.mpvAnime4KShaders,
        _ => throw ArgumentError('Unknown shader mode'),
      };
      final loaded = await owner.load(
        PlaybackPlan(
          contentKey: entry['contentKey'] as String? ?? 'local-fixture-$index',
          source: PlaybackSourceSnapshot.fromDataSource(
            NetworkSource(
              videoSource: entry['source'] as String,
              audioSource: null,
            ),
          ),
          timeline: const PlaybackTimeline(
            kind: PlaybackTimelineKind.onDemand,
            seekPolicy: PlaybackSeekPolicy.allowed,
          ),
          metadata: PlaybackMetadataHint(
            trust: PlaybackMetadataTrust.sourceHint,
            width: entry['width'] as int?,
            height: entry['height'] as int?,
          ),
          configuration: PlaybackConfiguration(
            hwdec: 'd3d11va',
            shaders: shaders.map(
              (name) => AssetUtils.tryGetPath(
                'assets/shaders/$name',
              )!,
            ),
            mediaOptions: const {
              'cache': 'yes',
              'cache-secs': '16',
              'demuxer-max-bytes': '4194304',
              'demuxer-max-back-bytes': '4194304',
            },
          ),
        ),
        start: PlaybackStartPolicy.pause,
      );
      check(loaded.outcome == LoadOutcome.ready, 'Source load failed');
      phase = '$name.loaded';
      final player = runtime.player!;
      final video = runtime.videoController!;
      final size = VideoOutputSizePolicy.fitWithinLimit(
        source: VideoOutputSizePolicy.videoDisplaySize(
          player.state.videoParams,
        ),
        limit: WindowsVideoOutputLimit.detected,
      )!;
      await video.setSize(width: size.width, height: size.height);
      check(
        (await owner.setPlaying(true)).outcome == CommandOutcome.applied,
        'Play failed',
      );
      phase = '$name.playing';
      await Future<void>.delayed(
        Duration(seconds: entry['seconds'] as int? ?? 5),
      );
      check(
        player.getProperty('hwdec-current') == 'd3d11va',
        'Decoder changed',
      );
      phase = '$name.pixels';
      if (config['checkFrames'] != false) {
        await WidgetsBinding.instance.endOfFrame;
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage();
        try {
          final pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          var low = 255, high = 0;
          for (var y = 20; y < image.height - 20; y += 4) {
            for (var x = 20; x < image.width - 20; x += 4) {
              final value = pixels.getUint8((y * image.width + x) * 4);
              if (value < low) low = value;
              if (value > high) high = value;
            }
          }
          check(high - low > 16, 'Blank video texture');
        } finally {
          image.dispose();
        }
      }
      phase = '$name.settled';
      for (var sample = 0; sample < 3; sample++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        await record('$name.$sample');
      }
      if (entry['maxCreatedTextures'] case final int limit) {
        final resources = (rows.last['native'] as Map)['resources'] as Map;
        final created = (resources['d3dTexture'] as Map)['created'] as int;
        check(
          created <= limit,
          'Unnecessary output texture allocations: $created > $limit',
        );
      }
      for (final transition
          in (entry['windowTransitions'] as List? ?? const []).cast<Map>()) {
        final stage = '$name.${transition['name']}';
        phase = '$stage.resize';
        await windowManager.ensureInitialized();
        fullscreenDisplay.value = transition['fullscreen'] as bool;
        await WidgetsBinding.instance.endOfFrame;
        await windowManager.setFullScreen(fullscreenDisplay.value);
        phase = '$stage.settling';
        await Future<void>.delayed(
          Duration(seconds: transition['seconds'] as int? ?? 5),
        );
        for (var sample = 0; sample < 3; sample++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          await record('$stage.$sample');
        }
      }
    }
    tracing = false;
    await traceTask;
    traceTask = null;
    phase = 'shutdown';
    owner.close();
    check(
      (await session.shutdown()).outcome == PlaybackShutdownOutcome.released,
      'Shutdown incomplete',
    );
    await runtime.released.timeout(const Duration(seconds: 15));
    phase = 'released';
    await Future<void>.delayed(const Duration(seconds: 3));
    await record('released');
    final idleSeconds = config['postReleaseSeconds'] as int? ?? 0;
    if (idleSeconds > 0) {
      await Future<void>.delayed(Duration(seconds: idleSeconds));
      for (var sample = 0; sample < 3; sample++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        await record('idle.$sample');
      }
    }
    final stats = rows.last['native'] as Map;
    final resources = stats['resources'] as Map;
    for (final resource in resources.values.cast<Map>()) {
      check(resource['count'] == 0, 'Native resource retained after release');
    }
    final checks = <Map<String, Object?>>[];
    report['memoryChecks'] = checks;
    double privateMedian(String name) {
      final samples =
          rows
              .where((row) => (row['stage'] as String).startsWith('$name.'))
              .map(
                (row) =>
                    ((row['process'] as Map)['privateBytes'] as num).toDouble(),
              )
              .toList()
            ..sort();
      check(samples.length == 3, 'Three settled samples required');
      return samples[1] / 1048576;
    }

    for (final entry in (config['memoryChecks'] as List? ?? const [])) {
      final before = privateMedian(entry['baseline'] as String);
      final after = privateMedian(entry['after'] as String);
      final growth = after - before;
      final passed = growth <= (entry['maxGrowthMiB'] as num);
      checks.add({
        'baseline': entry['baseline'],
        'after': entry['after'],
        'growthMiB': growth,
        'maxGrowthMiB': entry['maxGrowthMiB'],
        'passed': passed,
      });
    }
    check(
      checks.every((entry) => entry['passed'] == true),
      'Memory retention check failed',
    );
    final shaderChecks = <Map<String, Object?>>[];
    report['shaderChecks'] = shaderChecks;
    for (final entry in cases) {
      if (entry['maxActiveShaders'] case final int limit) {
        final name = entry['name'] as String;
        final samples = rows.where(
          (row) => (row['stage'] as String).startsWith('$name.'),
        );
        check(samples.isNotEmpty, 'Shader samples required');
        shaderChecks.add({
          'stage': name,
          'maxActiveShaders': limit,
          'actual': samples.map((row) => row['nativeShaderCount']).toList(),
          'passed': samples.every(
            (row) => (row['nativeShaderCount'] as int) <= limit,
          ),
        });
      }
    }
    check(
      shaderChecks.every((entry) => entry['passed'] == true),
      'Source shader policy check failed',
    );
    report['passed'] = true;
  } catch (error, stack) {
    report['error'] = '$error';
    report['stack'] = '$stack';
  } finally {
    tracing = false;
    await traceTask;
    await save();
    await gpu.invokeMethod<void>('stop');
  }
  exit(report['passed'] == true ? 0 : 1);
}
