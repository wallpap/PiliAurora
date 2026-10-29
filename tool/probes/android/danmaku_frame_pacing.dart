import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FramePhase;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pili_aurora/common/widgets/scale_app.dart';
import 'package:pili_aurora/pages/danmaku/interaction.dart';
import 'package:pili_aurora/pages/danmaku/live_layer.dart';
import 'package:pili_aurora/pages/danmaku/live_queue.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/pages/danmaku/window_screen.dart';
import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_media_clock_sampling.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_media_clock_worker.dart';
import 'package:pili_aurora/plugin/pl_player/playback/video_frame_timings.dart';
import 'package:pili_aurora/plugin/pl_player/utils/android_raster_scheduling.dart';
import 'package:pili_aurora/plugin/pl_player/utils/hardware_video_configuration.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

/// 独立 dev 包中的生产组件测量；配置、素材和报告均留在该包的 files 目录。
Future<void> main() async {
  ScaledWidgetsFlutterBinding.ensureInitialized();
  final directory = (await getExternalStorageDirectory())!;
  final config = File('${directory.path}/danmaku-probe.json');
  // 首次启动先由应用创建目录，主机随后推送配置和素材。
  while (!config.existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  final settings =
      jsonDecode(await config.readAsString()) as Map<String, dynamic>;
  final live = settings['mode'] == 'live';
  VideoController? video;
  _MediaClock? clock;
  final frames = PlaybackVideoFrameTimings(useRequestTimings: true);
  if (!live) {
    MediaKit.ensureInitialized();
    final player = await Player.create(
      configuration: const PlayerConfiguration(
        options: {'video-sync': 'display-resample', 'audio': 'no'},
      ),
    );
    video = await VideoController.create(
      player,
      configuration: hardwareVideoConfiguration(
        enabled: true,
        configured: 'mediacodec',
      ),
    );
    frames.setFrameTimelineSupported(video.frameTimelineSupported);
    player.observeProperty('display-sync-active').listen((value) {
      frames.setDisplaySyncActive(value == 'yes');
    });
    video.frameEvents.listen(frames.accept);
    video.outputProgress.listen((progress) async {
      if (frames.frameState.value.output == progress.token) return;
      frames.beginLoad(progress.token, Timeline.now);
      final revision = frames.beginSamplingChange(true, Timeline.now);
      final receipt = await video!.setVideoFrameSampling(progress.token, true);
      frames.completeSamplingChange(revision, receipt);
    });
    clock = _MediaClock(player);
    await player.setPlaylistMode(PlaylistMode.loop);
  }
  runApp(
    MaterialApp(
      home: _Probe(
        live: live,
        directory: directory,
        video: video,
        clock: clock,
        frames: frames,
      ),
    ),
  );
  if (video != null) {
    await video.player.open(Media(settings['media'] as String));
  }
}

class _MediaClock implements PlaybackMediaClock {
  _MediaClock(this.player) {
    subscription = player.stream.position.listen((_) => sample());
  }
  final Player player;
  final sampling = NativeMediaClockSampling();
  final events = StreamController<PlaybackMediaAnchor?>.broadcast(sync: true);
  late final StreamSubscription<Duration> subscription;
  int? entry;
  @override
  PlaybackMediaAnchor? currentMediaAnchor;
  @override
  Stream<PlaybackMediaAnchor?> get mediaAnchors => events.stream;

  void sample() {
    if (entry == null) {
      final index = int.tryParse(player.getProperty('playlist-pos'));
      if (index != null) {
        entry = int.tryParse(player.getProperty('playlist/$index/id'));
      }
    }
    final id = entry;
    if (id == null) return;
    sampling.request(
      () => sampleNativeMediaClockOnWorker(
        handleAddress: player.handle,
        libraryPath: player.nativeLibraryPath,
        playlistEntryId: id,
        continuity: 0,
      ),
      (anchor) {
        currentMediaAnchor = anchor;
        events.add(anchor);
      },
    );
  }

  Future<void> close() async {
    await subscription.cancel();
    await sampling.close();
    await events.close();
  }
}

class _Probe extends StatefulWidget {
  const _Probe({
    required this.live,
    required this.directory,
    required this.frames,
    this.video,
    this.clock,
  });
  final bool live;
  final Directory directory;
  final PlaybackVideoFrameTimings frames;
  final VideoController? video;
  final _MediaClock? clock;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  static const rates = [30, 60, 90, 120, 0];
  final messages = StreamController<LiveDanmakuMessage<void>>.broadcast(
    sync: true,
  );
  final timings = <FrameTiming>[];
  final samples = <Map<String, Object?>>[];
  final stages = <Map<String, Object?>>[];
  DanmakuWindowRenderer<void>? renderer;
  DanmakuInteractionHandle<void> Function()? interaction;
  AndroidRasterScheduling? affinity;
  int stage = 0, nextSecond = 0;
  int? fixtureStart, lastPosition;
  bool running = true, visible = true, recording = false;

  Map<String, Object?> layer() => Map<String, Object?>.from(
    Diagnostics.instance.readSources(prefix: 'danmaku.layer.').values.single
        as Map,
  );
  Map<String, Object?> scheduler() =>
      Map<String, Object?>.from(layer()['scheduler'] as Map);
  int get position => widget.live
      ? layer()['presentationTimeUs'] as int
      : renderer!.presentationTimeUs;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(onTimings);
    WidgetsBinding.instance.addPostFrameCallback(sample);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(run()));
  }

  void onTimings(List<FrameTiming> value) => timings.addAll(value);

  void sample(Duration _) {
    if (!mounted) return;
    if (recording && position != lastPosition) {
      lastPosition = position;
      final items = widget.live
          ? interaction!.call().snapshot
          : renderer!.interaction.snapshot;
      samples.add({
        'frameNumber':
            SchedulerBinding.instance.platformDispatcher.frameData.frameNumber,
        'targetUs': SchedulerBinding
            .instance
            .currentSystemFrameTimeStamp
            .inMicroseconds,
        'deliveredUs': Timeline.now,
        'positionUs': position,
        'scrollCount': items.where((item) => item.text.startsWith('滚动')).length,
        'active': items.length,
      });
    }
    WidgetsBinding.instance.addPostFrameCallback(sample);
  }

  void prepare(DanmakuWindowRenderer<void> target, int mediaUs) {
    fixtureStart ??= mediaUs;
    while (fixtureStart! + nextSecond * 1000000 < mediaUs + 1000000) {
      final second = nextSecond++;
      final from = fixtureStart! + second * 1000000;
      final contents = <DanmakuWindowContent<void>>[
        for (var i = 0; i < (second == 0 ? 6 : 2); i++)
          DanmakuWindowContent(
            'scroll-$second-$i',
            from + i * 150000,
            DanmakuContentItem<void>('滚动弹幕 $second-$i'),
          ),
        if (second.isEven) ...[
          DanmakuWindowContent(
            'top-$second',
            from,
            DanmakuContentItem<void>(
              '顶部固定弹幕 $second',
              type: DanmakuItemType.top,
            ),
          ),
          DanmakuWindowContent(
            'bottom-$second',
            from,
            DanmakuContentItem<void>(
              '底部固定弹幕 $second',
              type: DanmakuItemType.bottom,
            ),
          ),
        ],
      ]..sort((a, b) => a.sourceUs.compareTo(b.sourceUs));
      if (!target.prepare(
        contents,
        generation: target.generation,
        preparedUntilUs: from + 1000000,
      )) {
        throw StateError('弹幕素材准备失败');
      }
    }
    target.trimBefore(math.max(fixtureStart!, mediaUs - 1000000));
  }

  Future<void> run() async {
    try {
      if (widget.video case final video?) {
        await video.waitUntilFirstFrameRendered.timeout(
          const Duration(seconds: 20),
        );
        affinity = await AndroidRasterScheduling.open();
        affinity?.useAppCpus(true);
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      if (widget.live) {
        for (var i = 0; i < 60; i++) {
          messages.add(
            LiveDanmakuMessage<void>(
              identity: i,
              receivedAtUs: Timeline.now,
              text: '${i % 6 > 1 ? '滚动' : '固定'}直播弹幕 $i',
              type: i % 6 == 0
                  ? DanmakuItemType.top
                  : i % 6 == 1
                  ? DanmakuItemType.bottom
                  : DanmakuItemType.scroll,
            ),
          );
        }
      }
      for (var index = 0; index < rates.length; index++) {
        setState(() => stage = index);
        await Future<void>.delayed(const Duration(seconds: 4));
        samples.clear();
        timings.clear();
        lastPosition = null;
        final before = scheduler();
        final start = Timeline.now;
        recording = true;
        debugPrint('PILI_DANMAKU start $index');
        await Future<void>.delayed(const Duration(seconds: 8));
        recording = false;
        final end = Timeline.now;
        final after = scheduler();
        // FrameTiming 按批次交付，等待后按帧号关联测量窗口。
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        stages.add({
          'target': rates[index],
          'refreshHz': after['displayRefreshRate'],
          'startedUs': start,
          'endedUs': end,
          'before': before,
          'after': after,
          'affinity': affinity?.diagnostics,
          'videoFps': widget.video?.player.getProperty('container-fps'),
          'hwdec': widget.video?.player.getProperty('hwdec-current'),
          'displaySync': widget.video?.player.getProperty(
            'display-sync-active',
          ),
          'frames': List.of(samples),
          'timings': [
            for (final t in timings)
              {
                'frameNumber': t.frameNumber,
                'rasterStartUs': t.timestampInMicroseconds(
                  FramePhase.rasterStart,
                ),
                'rasterFinishUs': t.timestampInMicroseconds(
                  FramePhase.rasterFinish,
                ),
                'buildUs': t.buildDuration.inMicroseconds,
                'rasterUs': t.rasterDuration.inMicroseconds,
              },
          ],
        });
        await writeReport();
        debugPrint('PILI_DANMAKU stage $index complete');
      }
      final lifecycle = <String, bool>{};
      if (widget.live) {
        setState(() => running = false);
        lifecycle['pause'] = await remainsIdle();
        final before = scheduler()['updates'] as int;
        setState(() => running = true);
        await Future<void>.delayed(const Duration(seconds: 1));
        lifecycle['resume'] = (scheduler()['updates'] as int) > before;
        setState(() => visible = false);
        lifecycle['hide'] = await remainsIdle();
      }
      await writeReport(lifecycle: lifecycle);
      affinity?.restore();
      debugPrint('PILI_DANMAKU done');
    } catch (error) {
      recording = false;
      affinity?.restore();
      await writeReport(error: error.runtimeType.toString());
      debugPrint('PILI_DANMAKU failed ${error.runtimeType}');
    }
  }

  Future<bool> remainsIdle() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final before = scheduler();
    await Future<void>.delayed(const Duration(seconds: 1));
    final after = scheduler();
    return before['updates'] == after['updates'] &&
        before['frameRequests'] == after['frameRequests'];
  }

  Future<void> writeReport({Map<String, bool>? lifecycle, String? error}) =>
      File('${widget.directory.path}/danmaku-report.json').writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'mode': widget.live ? 'live' : 'point',
          'stages': stages,
          'lifecycle': lifecycle,
          'error': error,
        }),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        renderer ??= DanmakuWindowRenderer<void>(
          option: const DanmakuOption(
            fontSize: 20,
            duration: 8,
            staticDuration: 3,
            safeArea: false,
          ),
          size: size,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            if (widget.video case final video?)
              Center(
                child: FittedBox(child: SimpleVideo(controller: video)),
              ),
            if (widget.live)
              LiveDanmakuLayer<void>(
                messages: messages.stream,
                running: running,
                visible: visible,
                frameRate: rates[stage],
                size: size,
                option: const DanmakuOption(
                  fontSize: 20,
                  duration: 120,
                  staticDuration: 120,
                  safeArea: false,
                  massiveMode: true,
                ),
                createdInteraction: (get, _) => interaction = get,
              )
            else
              DanmakuWindowScreen<void>(
                renderer: renderer!,
                clock: widget.clock!,
                frameRate: rates[stage],
                frameSource: widget.frames,
                size: size,
                prepareFrame: (r, p, {required effectiveRate}) => prepare(r, p),
              ),
          ],
        );
      },
    ),
  );

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(onTimings);
    affinity?.restore();
    renderer?.dispose();
    unawaited(messages.close());
    unawaited(() async {
      await widget.clock?.close();
      await widget.video?.player.dispose();
    }());
    widget.frames.dispose();
    super.dispose();
  }
}
