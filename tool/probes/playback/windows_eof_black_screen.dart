import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_playback_runtime.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/plugin/pl_player/utils/native_video_options.dart';
import 'package:window_manager/window_manager.dart';

/// 用真实输出像素反驳“消费回执推进就等于画面正常”，仅使用显式本地配置。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows) throw UnsupportedError('Windows probe');
  final path = Platform.environment['PILIAURORA_BLACK_SCREEN_CONFIG'];
  if (path == null) throw ArgumentError('Explicit local config required');
  final config = jsonDecode(await File(path).readAsString()) as Map;
  final media = config['source'] as String;
  final audio = config['audioSource'] as String?;
  if (!File(media).existsSync() ||
      (audio != null && !File(audio).existsSync())) {
    throw ArgumentError('Local media fixtures required');
  }
  final output = File(config['output'] as String);
  await output.parent.create(recursive: true);
  final rounds = config['rounds'] as int? ?? 3;
  final decoder = config['decoder'] as String? ?? 'd3d11va';
  final boundary = GlobalKey();
  final display = ValueNotifier<VideoController?>(null);
  final label = ValueNotifier('initializing');
  final rows = <Map<String, Object?>>[];
  final logs = <Map<String, Object?>>[];
  final report = <String, Object?>{
    'schema': 1,
    'scope': 'productionSessionRuntime;localAv1;actualFlutterTexturePixels',
    'audioOutput': 'null',
    'decoder': decoder,
    'sequence': config['sequence'] ?? 'eof-seek-retry',
    'rounds': rounds,
    'rows': rows,
    'logs': logs,
    'completed': false,
    'reproduced': false,
    'counterexampleObserved': false,
    'allStagesHealthy': false,
  };
  Future<void> save() => output.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    flush: true,
  );
  await windowManager.ensureInitialized();
  await windowManager.setTitle('PiliAurora EOF pixel probe');
  await windowManager.setSize(const Size(1360, 880));
  await windowManager.center();
  MediaKit.ensureInitialized();
  runApp(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Column(
          children: [
            SizedBox(
              height: 48,
              child: Center(
                child: ValueListenableBuilder(
                  valueListenable: label,
                  builder: (_, value, _) =>
                      Text(value, style: const TextStyle(color: Colors.white)),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: RepaintBoundary(
                  key: boundary,
                  child: SizedBox(
                    width: 1280,
                    height: 720,
                    child: ValueListenableBuilder(
                      valueListenable: display,
                      builder: (_, video, _) => video == null
                          ? const ColoredBox(color: Colors.black)
                          : SimpleVideo(controller: video, aspectRatio: 16 / 9),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await windowManager.show();
  await windowManager.focus();
  const native = MethodChannel('com.alexmercerind/media_kit_video');
  NativePlaybackRuntime? runtime;
  PlaybackSession? session;
  PlaybackOwner? owner;
  StreamSubscription<PlayerLog>? subscription;
  void attach() => display.value = runtime?.videoController;
  Future<void> waitFor(bool Function() condition, String stage) async {
    final watch = Stopwatch()..start();
    while (!condition()) {
      if (watch.elapsedMilliseconds > 20000) throw TimeoutException(stage);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> create() async {
    final current = NativePlaybackRuntime(
      configuration: PlaybackRuntimeConfig(
        playerOptions: {'ao': 'null', ...nativeVideoPlayerOptions()},
        hardwareAccelerationEnabled: decoder != 'no',
        hardwareDecoder: decoder,
      ),
      diagnosticsExtra: () => const {},
    );
    runtime = current;
    current.videoControllerListenable.addListener(attach);
    session = PlaybackSession(runtime: current);
    owner = session!.attach();
  }

  Future<void> close() async {
    await subscription?.cancel();
    subscription = null;
    final current = runtime;
    if (current == null) return;
    current.videoControllerListenable.removeListener(attach);
    display.value = null;
    owner!.close();
    final result = await session!.shutdown();
    if (result.outcome != PlaybackShutdownOutcome.released) {
      throw StateError('Runtime did not release');
    }
    await current.released.timeout(const Duration(seconds: 15));
    runtime = null;
    owner = null;
    session = null;
  }

  PlaybackPlan plan(Duration start) => PlaybackPlan(
    contentKey: 'eof-black-screen-fixture',
    source: PlaybackSourceSnapshot.fromDataSource(
      NetworkSource(videoSource: media, audioSource: audio),
    ),
    timeline: const PlaybackTimeline(
      kind: PlaybackTimelineKind.onDemand,
      seekPolicy: PlaybackSeekPolicy.allowed,
    ),
    metadata: PlaybackMetadataHint(
      trust: PlaybackMetadataTrust.sourceHint,
      width: config['width'] as int? ?? 3840,
      height: config['height'] as int? ?? 2160,
    ),
    startPosition: start,
    configuration: PlaybackConfiguration(
      hwdec: decoder,
      mediaOptions: {
        'cache': 'yes',
        'cache-secs': '16',
        'demuxer-hysteresis-secs': '10.667',
        'demuxer-max-bytes': '4194304',
        'demuxer-max-back-bytes': '4194304',
        'video-sync': 'display-resample',
        'autosync': '0',
      },
    ),
  );
  Future<void> load(Duration start) async {
    final result = await owner!.load(
      plan(start),
      start: PlaybackStartPolicy.play,
    );
    if (result.outcome != LoadOutcome.ready) {
      throw StateError('Load outcome ${result.outcome.name}');
    }
    final player = runtime!.player!;
    subscription ??= player.stream.log.listen((event) {
      if (event.level == 'error' || event.level == 'fatal') {
        logs.add({
          'prefix': event.prefix,
          'level': event.level,
          'text': event.text,
        });
      }
    });
  }

  Map<String, Object?> state() {
    final current = runtime!;
    final player = current.player!;
    return {
      'runtimeId': current.runtimeId,
      'loadId': session!.loadId,
      'handle': player.handle,
      'textureId': current.videoController!.id.value,
      'positionMs': player.state.position.inMilliseconds,
      'sourceWidth': player.state.width,
      'sourceHeight': player.state.height,
      'outputWidth': current.videoController!.rect.value?.width,
      'outputHeight': current.videoController!.rect.value?.height,
      'audioPts': double.tryParse(player.getProperty('audio-pts')),
      'decoder': player.getProperty('hwdec-current'),
      'playing': player.state.playing,
      'buffering': player.state.buffering,
      'completed': player.state.completed,
      'phase': session!.currentSnapshot.phase.name,
      'videoProgressing': session!.currentSnapshot.actual.videoProgressing,
      ...current.videoFrameDiagnostics,
    };
  }

  Future<Map<String, Object?>> pixels(String name) async {
    await WidgetsBinding.instance.endOfFrame;
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 0.5);
    try {
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      var low = 255, high = 0, alphaLow = 255, alphaHigh = 0;
      var bright = 0, count = 0, fingerprint = 0;
      for (var y = image.height ~/ 8; y < image.height * 7 ~/ 8; y += 4) {
        for (var x = image.width ~/ 8; x < image.width * 7 ~/ 8; x += 4) {
          final offset = (y * image.width + x) * 4;
          final value =
              (bytes.getUint8(offset) +
                  bytes.getUint8(offset + 1) +
                  bytes.getUint8(offset + 2)) ~/
              3;
          if (value < low) low = value;
          if (value > high) high = value;
          final alpha = bytes.getUint8(offset + 3);
          if (alpha < alphaLow) alphaLow = alpha;
          if (alpha > alphaHigh) alphaHigh = alpha;
          if (value > 24) bright++;
          count++;
          fingerprint = (fingerprint * 31 + value) & 0x7fffffff;
        }
      }
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File('${output.parent.path}/$name.png')
          .writeAsBytes(png.buffer.asUint8List());
      return {
        'low': low,
        'high': high,
        'brightFraction': bright / count,
        'fingerprint': fingerprint,
        'black': high <= 24,
        'alphaLow': alphaLow,
        'alphaHigh': alphaHigh,
      };
    } finally {
      image.dispose();
    }
  }

  Future<bool> observe(String stage) async {
    label.value = stage;
    final before = state();
    final samples = <Map<String, Object?>>[];
    for (var index = 0; index < 3; index++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      samples.add(await pixels('$stage.$index'));
    }
    final after = state();
    final positionDelta =
        (after['positionMs'] as int) - (before['positionMs'] as int);
    final audioBefore = before['audioPts'] as double?;
    final audioAfter = after['audioPts'] as double?;
    final consumedDelta =
        (after['consumedFrameSamples'] as int) -
        (before['consumedFrameSamples'] as int);
    final black = samples.every((sample) => sample['black'] == true);
    final advancing =
        positionDelta >= 500 &&
        audioBefore != null &&
        audioAfter != null &&
        audioAfter - audioBefore >= 0.5 &&
        consumedDelta >= 10;
    final counterexample = advancing && black;
    Map<String, dynamic>? desktop;
    if (config['desktopCapture'] == true) {
      final receipt = File('${output.parent.path}/desktop-$stage.json');
      await File('${output.parent.path}/capture-request.json').writeAsString(
        jsonEncode({'stage': stage}),
        flush: true,
      );
      await waitFor(receipt.existsSync, 'desktop pixel receipt');
      desktop =
          jsonDecode(await receipt.readAsString()) as Map<String, dynamic>;
    }
    final confirmed =
        counterexample && (desktop == null || desktop['blank'] == true);
    if (confirmed) report['counterexampleObserved'] = true;
    rows.add({
      'stage': stage,
      'before': before,
      'after': after,
      'pixels': samples,
      'positionDeltaMs': positionDelta,
      'audioDelta': audioBefore == null || audioAfter == null
          ? null
          : audioAfter - audioBefore,
      'consumedDelta': consumedDelta,
      'counterexample': confirmed,
      'advancing': advancing,
      'black': black,
      'desktop': desktop,
      'native': await native.invokeMapMethod<String, Object?>(
        'VideoOutputManager.MemoryStats',
      ),
    });
    await save();
    stdout.writeln(
      'EOF_PROBE $stage black=$black advancing=$advancing consumed=$consumedDelta',
    );
    return confirmed;
  }

  try {
    for (var round = 0; round < rounds; round++) {
      await create();
      final endMs = config['durationMs'] as int;
      final retryOnly = config['sequence'] == 'retry-only';
      await load(
        retryOnly ? Duration.zero : Duration(milliseconds: endMs - 1200),
      );
      if (!retryOnly) {
        await waitFor(
          () => session!.currentSnapshot.phase == PlaybackPhase.ended,
          'natural EOF',
        );
        await Future<void>.delayed(
          Duration(milliseconds: config['eofDwellMs'] as int? ?? 1000),
        );
        await owner!.seek(Duration.zero);
        await owner!.setPlaying(true);
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      final firstBlack = await observe(
        retryOnly ? 'r$round.initial' : 'r$round.eof-replay',
      );
      var seekBlack = false;
      if (!retryOnly) {
        await Future<void>.delayed(const Duration(seconds: 2));
        await owner!.seek(Duration.zero);
        await Future<void>.delayed(const Duration(seconds: 2));
        seekBlack = await observe('r$round.seek-zero');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      final result = await owner!.retry();
      if (result.outcome != LoadOutcome.ready) throw StateError('Retry failed');
      await Future<void>.delayed(const Duration(seconds: 1));
      final reloadBlack = await observe('r$round.same-instance-retry');
      final second = await owner!.retry();
      if (second.outcome != LoadOutcome.ready) {
        throw StateError('Second retry failed');
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      final secondReloadBlack = await observe('r$round.second-retry');
      final reopenPosition = runtime!.player!.state.position;
      await close();
      await create();
      await load(reopenPosition);
      await Future<void>.delayed(const Duration(seconds: 1));
      await observe('r$round.recreated-instance');
      final reopened =
          rows.last['advancing'] == true && rows.last['black'] == false;
      final reproduced =
          ((firstBlack || seekBlack) && reloadBlack ||
              reloadBlack && secondReloadBlack) &&
          reopened;
      if (reproduced) report['reproduced'] = true;
      await close();
      if (reproduced && config['stopAfterReproduction'] != false) break;
    }
    report['completed'] = true;
    report['allStagesHealthy'] =
        rows.isNotEmpty &&
        rows.every(
          (row) =>
              row['advancing'] == true &&
              row['black'] == false &&
              (row['desktop'] as Map?)?['blank'] != true,
        );
  } catch (error, stack) {
    report['error'] = '$error';
    report['stack'] = '$stack';
  } finally {
    await close();
    report['afterRelease'] = await native.invokeMapMethod<String, Object?>(
      'VideoOutputManager.MemoryStats',
    );
    await save();
  }
  exit(
    report['completed'] != true
        ? 2
        : report['reproduced'] == true
        ? 1
        : 0,
  );
}
