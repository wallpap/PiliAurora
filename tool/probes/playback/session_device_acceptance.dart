import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_playback_runtime.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/services/windows_video_output_limit.dart';
import 'package:window_manager/window_manager.dart';

/// 本地样片的生产会话设备验收；报告不保存地址、账号或原生日志。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) await windowManager.ensureInitialized();
  MediaKit.ensureInitialized();
  const media = String.fromEnvironment('DEVICE_MEDIA');
  const audio = String.fromEnvironment('DEVICE_AUDIO');
  const shader = String.fromEnvironment('DEVICE_SHADER');
  const output = String.fromEnvironment('DEVICE_REPORT');
  const defaultSoakSeconds = int.fromEnvironment(
    'DEVICE_SOAK_SECONDS',
    defaultValue: 60,
  );
  const seekTargetMs = int.fromEnvironment(
    'DEVICE_SEEK_MS',
    defaultValue: 2400,
  );
  if (media.isEmpty || output.isEmpty) throw ArgumentError('需要媒体和报告路径');
  final configFile = File('$output.config.json');
  final config = configFile.existsSync()
      ? jsonDecode(await configFile.readAsString()) as Map<String, dynamic>
      : <String, dynamic>{};
  final skipRapid = config['skipRapid'] == true;
  final rapidOnly = config['rapidOnly'] == true;
  final diagnosticReplayOnly = config['diagnosticReplayOnly'] == true;
  final startupOnly = config['startupOnly'] == true;
  final switchSources = (config['switchSources'] as List?)?.cast<String>();
  final switchOnly = switchSources != null;
  final mountAfterLoad = config['mountAfterLoad'] == true;
  var canMount = !mountAfterLoad;
  final soakSeconds = config['soakSeconds'] as int? ?? defaultSoakSeconds;
  final decoder =
      config['decoder'] as String? ??
      (Platform.isWindows ? 'd3d11va' : 'mediacodec');
  final report = <String, Object?>{
    'platform': Platform.operatingSystem,
    'requestedDecoder': decoder,
    'seekTargetMs': seekTargetMs,
  };
  final cases = <Map<String, Object?>>[];
  report['cases'] = cases;
  final file = File(output);
  final boundary = GlobalKey();
  final display = ValueNotifier<VideoController?>(null);
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: boundary,
            child: SizedBox(
              width: 480,
              height: 270,
              child: ValueListenableBuilder(
                valueListenable: display,
                builder: (context, video, _) => video == null
                    ? const ColoredBox(color: Colors.black)
                    : FittedBox(child: SimpleVideo(controller: video)),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> save() async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
  }

  void check(bool value, String reason) {
    if (!value) throw _CheckFailure(reason);
  }

  Future<void> waitFor(bool Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('device evidence');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<Map<String, Object?>> pixels() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await WidgetsBinding.instance.endOfFrame;
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    var low = 255, high = 0, fingerprint = 0;
    for (var y = 20; y < image.height - 20; y += 4) {
      for (var x = 20; x < image.width - 20; x += 4) {
        final offset = (y * image.width + x) * 4;
        final value =
            (bytes.getUint8(offset) +
                bytes.getUint8(offset + 1) +
                bytes.getUint8(offset + 2)) ~/
            3;
        if (value < low) low = value;
        if (value > high) high = value;
        fingerprint = (fingerprint * 31 + value) & 0x7fffffff;
      }
    }
    image.dispose();
    check(high - low > 40, 'texture pixels have insufficient contrast');
    return {'low': low, 'high': high, 'fingerprint': fingerprint};
  }

  Future<void> test(
    String name,
    Future<Map<String, Object?>> Function() body,
  ) async {
    if (startupOnly && name != 'paused-load' && name != 'shutdown-released') {
      return;
    }
    if (switchOnly &&
        name != 'paused-load' &&
        name != 'shutdown-released' &&
        !name.startsWith('switch-')) {
      return;
    }
    if (diagnosticReplayOnly &&
        !{
          'paused-load',
          'recoverable-log-replay',
          'fatal-file-error',
          'shutdown-released',
        }.contains(name)) {
      return;
    }
    if (rapidOnly &&
        !{
          'paused-load',
          'rapid-load-latest-pause',
          'post-rapid-reload',
          'shutdown-released',
        }.contains(name)) {
      return;
    }
    final watch = Stopwatch()..start();
    try {
      cases.add({
        'name': name,
        ...await body(),
        'passed': true,
        'ms': watch.elapsedMilliseconds,
      });
    } catch (error, stack) {
      // 异常正文可能包含媒体地址；报告保留类型与当前阶段以便本地定位。
      cases.add({
        'name': name,
        'passed': false,
        'errorType': error.runtimeType.toString(),
        'stack': stack.toString().split('\n').take(8).toList(),
        if (error is _CheckFailure) 'reason': error.reason,
        'ms': watch.elapsedMilliseconds,
      });
    }
    await save();
    debugPrint('DEVICE_ACCEPTANCE ${jsonEncode(cases.last)}');
  }

  PlaybackPlan plan({String? sound, bool live = false, String? source}) =>
      PlaybackPlan(
        contentKey: live || switchOnly ? 'fixture-live-policy' : 'fixture',
        source: PlaybackSourceSnapshot.fromDataSource(
          NetworkSource(videoSource: source ?? media, audioSource: sound),
        ),
        timeline: PlaybackTimeline(
          kind: live || switchOnly
              ? PlaybackTimelineKind.live
              : PlaybackTimelineKind.onDemand,
          seekPolicy: live || switchOnly
              ? PlaybackSeekPolicy.disabled
              : PlaybackSeekPolicy.allowed,
        ),
        configuration: PlaybackConfiguration(
          hwdec: decoder,
        ),
      );
  final runtime = NativePlaybackRuntime(
    configuration: PlaybackRuntimeConfig(
      playerOptions: const {'ao': 'null', 'gpu-dumb-mode': 'no'},
      hardwareAccelerationEnabled: decoder != 'no',
      hardwareDecoder: decoder,
    ),
    diagnosticsExtra: () => const {},
  );
  final session = PlaybackSession(runtime: runtime);
  final terminalEvents = <Map<String, Object?>>[];
  final runtimeEvents = runtime.events.listen((event) {
    if (event is PlaybackRuntimeFailure) {
      terminalEvents.add({
        'loadId': event.loadId,
        'category': event.failure.category.name,
        'operation': event.failure.operation,
        'cause': event.failure.cause,
      });
    } else if (event is PlaybackRuntimeEnded) {
      terminalEvents.add({'loadId': event.loadId, 'ended': true});
    }
    report['terminalEvents'] = terminalEvents;
  });
  final owner = session.attach();
  final mount = Timer.periodic(const Duration(milliseconds: 20), (_) {
    if (!canMount) return;
    if (display.value != runtime.videoController) {
      display.value = runtime.videoController;
    }
  });
  double? property(String key) =>
      double.tryParse(runtime.player!.getProperty(key));
  Future<Map<String, Object?>> advancing() async {
    final beforePixels = switchOnly ? await pixels() : null;
    final before = property('time-pos');
    final audioBefore = property('audio-pts');
    await Future<void>.delayed(const Duration(seconds: 2));
    final after = property('time-pos');
    final audioAfter = property('audio-pts');
    check(
      before != null && after != null && after > before + .5,
      'video timeline stopped',
    );
    if (audioBefore != null) {
      check(
        audioAfter != null && audioAfter > audioBefore + .5,
        'audio timeline stopped',
      );
    }
    final afterPixels = await pixels();
    if (beforePixels != null) {
      check(
        beforePixels['fingerprint'] != afterPixels['fingerprint'],
        'texture image stopped while timeline advanced',
      );
    }
    return {
      'positionDelta': after! - before!,
      'audioDelta': audioBefore == null || audioAfter == null
          ? null
          : audioAfter - audioBefore,
      'decoder': runtime.player!.getProperty('hwdec-current'),
      'codec': runtime.player!.getProperty('video-codec'),
      ...afterPixels,
    };
  }

  try {
    await test('paused-load', () async {
      final result = await owner.load(plan(), start: PlaybackStartPolicy.pause);
      report['initialLoad'] = {
        'outcome': result.outcome.name,
        'operation': result.failure?.operation,
        'category': result.failure?.category.name,
        'cause': result.failure?.cause,
      };
      check(result.outcome == LoadOutcome.ready, 'load failed');
      canMount = true;
      check(!runtime.player!.state.playing, 'pause intent lost');
      if (Platform.isWindows) {
        final expected = VideoOutputSizePolicy.fitWithinLimit(
          source: VideoOutputSizePolicy.videoDisplaySize(
            runtime.player!.state.videoParams,
          ),
          limit: WindowsVideoOutputLimit.detected,
        );
        final rect = runtime.videoController!.rect.value;
        report['initialOutput'] = {
          'expectedWidth': expected?.width,
          'expectedHeight': expected?.height,
          'actualWidth': rect?.width,
          'actualHeight': rect?.height,
        };
        check(
          expected != null &&
              rect?.width == expected.width &&
              rect?.height == expected.height,
          'ready output still needs a visible startup resize',
        );
      }
      return {
        'outcome': result.outcome.name,
        'output': session.currentSnapshot.presentation.outputStrategy.name,
        'evidence': session.currentSnapshot.presentation.evidence,
        'loadId': session.loadId,
      };
    });
    if (switchSources != null) {
      await owner.setPlaying(true);
      for (var index = 0; index < switchSources.length; index++) {
        await test('switch-$index', () async {
          if (Platform.isWindows) {
            await windowManager.setSize(
              index.isEven ? const Size(640, 400) : const Size(320, 180),
            );
          }
          final loaded = await owner.load(
            plan(source: switchSources[index]),
            start: PlaybackStartPolicy.preserve,
          );
          check(loaded.outcome == LoadOutcome.ready, 'stream switch failed');
          await waitFor(
            () => runtime.player!.state.position.inMilliseconds > 500,
          );
          return {
            'outcome': loaded.outcome.name,
            'loadId': session.loadId,
            ...await advancing(),
          };
        });
      }
    }
    if (diagnosticReplayOnly) {
      await test('recoverable-log-replay', () async {
        await owner.setPlaying(true);
        // 回放原生诊断流，覆盖 FFmpeg 仍继续解码时的损坏包与回退日志。
        final dynamic diagnosticInput = runtime.player!;
        for (final message in const [
          'flv: Attempted to read next track in single-track mode.',
          'h264: Invalid NAL unit size (3346 > 1157).',
          'h264: missing picture in access unit with size 1191',
          'Could not open codec.',
        ]) {
          diagnosticInput.errorController.add(message);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          report['diagnosticReplayPhase'] = session.currentSnapshot.phase.name;
          check(
            session.currentSnapshot.phase == PlaybackPhase.ready,
            'diagnostic log changed session phase',
          );
        }
        check(
          (await owner.setPlaying(false)).outcome == CommandOutcome.applied &&
              (await owner.setPlaying(true)).outcome == CommandOutcome.applied,
          'controls stopped after diagnostic log',
        );
        await waitFor(
          () => runtime.player!.state.position.inMilliseconds > 500,
        );
        return advancing();
      });
      await test('fatal-file-error', () async {
        final watch = Stopwatch()..start();
        final result = await owner.load(
          plan(source: '$media.missing-fixture'),
          start: PlaybackStartPolicy.pause,
        );
        check(result.outcome == LoadOutcome.failed, 'fatal open did not fail');
        check(
          watch.elapsed < const Duration(seconds: 5),
          'fatal open waited for deadline',
        );
        final restored = await owner.load(
          plan(),
          start: PlaybackStartPolicy.pause,
        );
        check(
          restored.outcome == LoadOutcome.ready,
          'recovery after fatal open failed',
        );
        return {
          'outcome': result.outcome.name,
          'operation': result.failure?.operation,
        };
      });
    }
    await test('play-and-pixels', () async {
      check(
        (await owner.setPlaying(true)).outcome == CommandOutcome.applied,
        'play failed',
      );
      await waitFor(() => runtime.player!.state.position.inMilliseconds > 500);
      return advancing();
    });
    await test('sampling-active', () async {
      await waitFor(
        () => runtime.frameSource.frameState.value.videoSamples != null,
      );
      final state = runtime.frameSource.frameState.value;
      check(state.admission.name == 'active', 'sampling did not become active');
      check(
        state.videoSamples!.output == state.output,
        'sampling output differs',
      );
      return {
        'epoch': state.epoch,
        'generation': state.samplingGeneration,
        'kind': state.videoSamples!.kind.name,
      };
    });
    await test('paused-seek', () async {
      await owner.setPlaying(false);
      final result = await owner.seek(
        const Duration(milliseconds: seekTargetMs),
      );
      check(result.outcome == CommandOutcome.applied, 'seek failed');
      // seek 过渡期间可短暂报告请求位置，完成后再核对实际落点。
      await waitFor(() => runtime.player!.getProperty('seeking') == 'no');
      await waitFor(
        () =>
            (runtime.player!.state.position.inMilliseconds - seekTargetMs)
                .abs() <
            500,
      );
      check(!runtime.player!.state.playing, 'seek changed intent');
      await waitFor(
        () => runtime.frameSource.frameState.value.admission.name == 'blocked',
      );
      check(
        runtime.frameSource.frameState.value.videoSamples == null,
        'paused seek retained phase samples',
      );
      return {
        'positionMs': runtime.player!.state.position.inMilliseconds,
        ...await pixels(),
      };
    });
    if (audio.isNotEmpty) {
      await test('external-audio', () async {
        final result = await owner.load(
          plan(sound: audio),
          start: PlaybackStartPolicy.play,
        );
        check(
          result.outcome == LoadOutcome.ready,
          'external audio load failed',
        );
        await waitFor(
          () => property('audio-pts') != null && property('audio-pts')! > .3,
        );
        return advancing();
      });
    }
    if (!skipRapid) {
      await test('rapid-load-latest-pause', () async {
        final tasks = <Future<LoadResult>>[];
        final count = config['rapidCount'] as int? ?? 10;
        final interval = Duration(
          milliseconds: config['rapidIntervalMs'] as int? ?? 15,
        );
        for (var i = 0; i < count; i++) {
          tasks.add(
            owner.load(
              plan(),
              start: i == count - 1
                  ? PlaybackStartPolicy.pause
                  : PlaybackStartPolicy.play,
            ),
          );
          await Future<void>.delayed(interval);
        }
        final results = await Future.wait(tasks);
        report['rapidResults'] = results
            .map(
              (r) => {
                'outcome': r.outcome.name,
                'operation': r.failure?.operation,
                'category': r.failure?.category.name,
                'cause': r.failure?.cause,
              },
            )
            .toList();
        report['rapidPhase'] = session.currentSnapshot.phase.name;
        report['nativePlaylistCount'] = runtime.player!.getProperty(
          'playlist-count',
        );
        report['nativeIdle'] = runtime.player!.getProperty('idle-active');
        check(results.last.outcome == LoadOutcome.ready, 'latest load failed');
        check(
          results.every(
            (r) =>
                r.outcome == LoadOutcome.ready ||
                r.outcome == LoadOutcome.superseded,
          ),
          'rapid load returned a failure',
        );
        check(!runtime.player!.state.playing, 'latest pause lost');
        return {
          'outcomes': results.map((r) => r.outcome.name).toList(),
          'loadId': session.loadId,
          ...await pixels(),
        };
      });
      await test('post-rapid-reload', () async {
        final result = await owner.load(
          plan(),
          start: PlaybackStartPolicy.pause,
        );
        check(result.outcome == LoadOutcome.ready, 'subsequent load failed');
        check(!runtime.player!.state.playing, 'subsequent pause lost');
        check(
          (await owner.setPlaying(true)).outcome == CommandOutcome.applied,
          'subsequent play failed',
        );
        await waitFor(
          () => runtime.player!.state.position.inMilliseconds > 500,
        );
        return advancing();
      });
    }
    if (decoder != 'no') {
      await test('software-hardware-switch', () async {
        await owner.setPlaying(false);
        final off = await owner.setDecoder(const PlaybackDecoder('no'));
        final on = await owner.setDecoder(
          PlaybackDecoder(decoder),
        );
        check(
          off.outcome == CommandOutcome.applied &&
              on.outcome == CommandOutcome.applied,
          'decoder switch failed',
        );
        check(!runtime.player!.state.playing, 'decoder changed pause');
        await owner.setPlaying(true);
        return advancing();
      });
    }
    await test('audio-only-restore', () async {
      final off = await owner.setAudioOnly(true);
      final on = await owner.setAudioOnly(false);
      check(
        off.outcome == CommandOutcome.applied &&
            on.outcome == CommandOutcome.applied,
        'audio mode failed',
      );
      return advancing();
    });
    if (shader.isNotEmpty) {
      await test('live-policy-shader-paused', () async {
        final loaded = await owner.load(
          plan(live: true),
          start: PlaybackStartPolicy.pause,
        );
        final before = session.loadId;
        final changed = await owner.setShader([shader]);
        final cleared = await owner.setShader([]);
        check(
          loaded.outcome == LoadOutcome.ready &&
              changed.outcome == CommandOutcome.applied &&
              cleared.outcome == CommandOutcome.applied,
          'shader failed',
        );
        check(!runtime.player!.state.playing, 'shader changed pause');
        check(session.loadId == before + 2, 'live policy must reload');
        return {'reloads': session.loadId - before};
      });
    }
    await test('steady-playback', () async {
      final loaded = await owner.load(plan(), start: PlaybackStartPolicy.play);
      check(loaded.outcome == LoadOutcome.ready, 'steady load failed');
      final samples = <Map<String, Object?>>[];
      final watch = Stopwatch()..start();
      while (watch.elapsed.inSeconds < soakSeconds) {
        samples.add({
          'second': watch.elapsed.inSeconds,
          'rss': ProcessInfo.currentRss,
          'phase': session.currentSnapshot.phase.name,
          'position': property('time-pos'),
          'decoder': runtime.player!.getProperty('hwdec-current'),
        });
        final duration = runtime.player!.state.duration;
        if (duration > Duration.zero &&
            duration - runtime.player!.state.position <
                const Duration(seconds: 5)) {
          await owner.seek(const Duration(seconds: 1));
        }
        await Future<void>.delayed(const Duration(seconds: 2));
        check(
          session.currentSnapshot.phase == PlaybackPhase.ready,
          'playback left ready',
        );
      }
      return {
        'seconds': watch.elapsed.inSeconds,
        'samples': samples,
        ...await pixels(),
      };
    });
    await test('natural-eof', () async {
      final duration = runtime.player!.state.duration;
      check(duration > const Duration(seconds: 3), 'fixture too short for EOF');
      await owner.seek(duration - const Duration(seconds: 1));
      await owner.setPlaying(true);
      await waitFor(() => session.currentSnapshot.phase == PlaybackPhase.ended);
      check(
        !session.currentSnapshot.intent.playing,
        'EOF retained play intent',
      );
      return {'phase': session.currentSnapshot.phase.name};
    });
  } finally {
    mount.cancel();
    display.value = null;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    owner.close();
    await test('shutdown-released', () async {
      final result = await session.shutdown();
      check(
        result.outcome == PlaybackShutdownOutcome.released,
        'cleanup incomplete',
      );
      await runtime.released.timeout(const Duration(seconds: 10));
      return {'outcome': result.outcome.name};
    });
    report['passed'] = cases.every((c) => c['passed'] == true);
    await runtimeEvents.cancel();
    await save();
    debugPrint('DEVICE_ACCEPTANCE_DONE ${report['passed']}');
  }
  if (Platform.isWindows) {
    // 让 runner 在主线程结束窗口和 COM 生命周期。
    await windowManager.destroy();
  } else {
    exit(report['passed'] == true ? 0 : 1);
  }
}

class _CheckFailure implements Exception {
  const _CheckFailure(this.reason);
  final String reason;
}
