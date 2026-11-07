import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/cache.dart';
import 'package:pili_aurora/pages/danmaku/file_reader.dart';
import 'package:pili_aurora/pages/danmaku/priority.dart';
import 'package:pili_aurora/pages/danmaku/merge.dart';
import 'package:pili_aurora/pages/danmaku/timeline_range.dart';
import 'package:pili_aurora/pages/danmaku/window_coordinator.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/pages/danmaku/window_screen.dart';
import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';
import 'package:window_manager/window_manager.dart';

import '../../experiments/danmaku/density_metrics.dart';

// 参数：输出目录、视频、弹幕 protobuf、起点毫秒、每桶上限、逐帧预算、可选merge。
// 独立窗口、静音、只读输入；输出仅含聚合指标和本地画面，不启动业务服务。
Future<void> main(List<String> args) async {
  try {
    await _runProbe(args);
  } catch (error, stack) {
    if (args.isNotEmpty) {
      await Directory(args.first).create(recursive: true);
      await File('${args.first}/error.txt').writeAsString('$error\n$stack');
    }
    exit(1);
  }
}

Future<void> _runProbe(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows || args.length < 4) {
    throw ArgumentError('需要 Windows 及本地输入');
  }
  final output = Directory(args[0]);
  await output.create(recursive: true);
  final startMs = int.parse(args[3]);
  final cap = args.length > 4 ? int.parse(args[4]) : danmakuCandidatesPerBucket;
  final perFrame = args.length > 5 ? int.parse(args[5]) : 8;
  final retained = DanmakuPriorityRetention(
    maxElements: 36000,
    maxPerBucket: cap,
    maxBytes: 20 * 1024 * 1024,
  );
  final elements = <DanmakuElem>[];
  await for (final batch in readDanmakuFile(File(args[2]))) {
    for (final e in batch) {
      if (e.progress >= startMs &&
          e.progress < startMs + 30000 &&
          e.mode >= 1 &&
          e.mode <= 6) {
        elements.add(e);
      }
    }
  }
  final merge = args.length > 6 && args[6] == 'merge';
  final input = merge ? await mergeDanmakuInBackground(elements) : elements;
  for (var i = 0; i < input.length; i++) {
    retained.add(i, input[i]);
  }
  final source = _Source(
    DanmakuCache()..addFileElements(retained.buckets.values.expand((e) => e)),
    input,
  );
  MediaKit.ensureInitialized();
  final player = await Player.create(
    configuration: const PlayerConfiguration(options: {'ao': 'null'}),
  );
  final video = await VideoController.create(
    player,
    configuration: const VideoControllerConfiguration(hwdec: 'd3d11va'),
  );
  await player.open(
    Media(File(args[1]).absolute.path, start: Duration(milliseconds: startMs)),
    play: false,
  );
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1280, 720),
      center: true,
      title: 'PiliAurora density probe',
    ),
  );
  await windowManager.show();
  await windowManager.show();
  await windowManager.focus();
  runApp(
    MaterialApp(
      home: _Probe(
        source: source,
        player: player,
        video: video,
        output: output,
        startMs: startMs,
        cap: cap,
        perFrame: perFrame,
        merge: merge,
      ),
    ),
  );
}

class _Source implements DanmakuTimelineSource {
  _Source(this.cache, this.input);
  final DanmakuCache cache;
  final List<DanmakuElem> input;
  @override
  Stream<DanmakuSourceChange> get changes => const Stream.empty();
  @override
  Future<void> ensureRange(int startUs, int endUs) async {}
  @override
  DanmakuTimelineRange readRange(
    int startUs,
    int endUs, {
    int? maxEntriesPerBucket,
  }) =>
      cache.readRange(startUs, endUs, maxEntriesPerBucket: maxEntriesPerBucket);
}

class _Clock implements PlaybackMediaClock {
  _Clock(this.startMs);
  final int startMs;
  final events = StreamController<PlaybackMediaAnchor?>.broadcast();
  int? started;
  @override
  PlaybackMediaAnchor get currentMediaAnchor => PlaybackMediaAnchor(
    positionUs: startMs * 1000,
    observedAtUs: started ?? Timeline.now,
    effectiveRate: 1,
    advancing: started != null,
    ready: true,
    continuity: 0,
    validForUs: 60000000,
  );
  @override
  Stream<PlaybackMediaAnchor?> get mediaAnchors => events.stream;
  void play() {
    started = Timeline.now;
    events.add(currentMediaAnchor);
  }
}

class _Probe extends StatefulWidget {
  const _Probe({
    required this.source,
    required this.player,
    required this.video,
    required this.output,
    required this.startMs,
    required this.cap,
    required this.perFrame,
    required this.merge,
  });
  final _Source source;
  final Player player;
  final VideoController video;
  final Directory output;
  final int startMs;
  final int cap;
  final int perFrame;
  final bool merge;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final boundary = GlobalKey();
  late final clock = _Clock(widget.startMs);
  DanmakuWindowRenderer<DensityTag>? renderer;
  DanmakuWindowCoordinator<DensityTag>? coordinator;
  final timings = <FrameTiming>[];
  DanmakuDensityMetrics? metrics;
  bool collectingTimings = false;
  int? videoStartMs;
  int peakActive = 0;
  int peakBytes = 0;
  bool measuring = false;
  int incompleteFrames = 0;
  int sampledFrames = 0;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback((values) {
      if (collectingTimings) timings.addAll(values);
    });
    WidgetsBinding.instance.addPostFrameCallback(sample);
    WidgetsBinding.instance.addPostFrameCallback((_) => run());
  }

  void sample(Duration _) {
    if (measuring && renderer != null) {
      sampledFrames++;
      final target = renderer!;
      if (target.validUntilUs <= target.presentationTimeUs) incompleteFrames++;
      if (target.activeCount > peakActive) peakActive = target.activeCount;
      if (target.workingSetBytes > peakBytes) {
        peakBytes = target.workingSetBytes;
      }
      metrics!.sample(
        target.interaction.snapshot,
        widget.startMs * 1000 + Timeline.now - clock.started!,
      );
    }
    if (mounted) WidgetsBinding.instance.addPostFrameCallback(sample);
  }

  Map<String, int> distribution(Iterable<int> input) {
    final values = input.toList()..sort();
    return values.isEmpty
        ? {}
        : {
            'p50': values[values.length ~/ 2],
            'p95': values[(values.length * .95).floor()],
            'max': values.last,
          };
  }

  Future<void> run() async {
    try {
      await Future<void>.delayed(const Duration(seconds: 2));
      await widget.video.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 20),
      );
      videoStartMs = widget.player.state.position.inMilliseconds;
      await widget.player.play();
      clock.play();
      measuring = true;
      collectingTimings = true;
      await Future<void>.delayed(const Duration(seconds: 10));
      final image =
          await (boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${widget.output.path}/frame.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
      await Future<void>.delayed(const Duration(seconds: 20));
      collectingTimings = false;
      await Future<void>.delayed(const Duration(seconds: 8));
      measuring = false;
      await File('${widget.output.path}/report.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'scope': 'windows_profile_real_video_texture_flutter_frame_timing',
          'clock': 'probe_monotonic_clock_anchored_at_player_play',
          'startMs': widget.startMs,
          'cap': widget.cap,
          'perFrame': widget.perFrame,
          'sampledFrames': sampledFrames,
          'incompleteFrames': incompleteFrames,
          'merge': widget.merge,
          'tailSeconds': 8,
          'inputByWeight': weightCounts(widget.source.input),
          'retainedByWeight': weightCounts(
            widget.source.cache
                .readRange(
                  widget.startMs * 1000,
                  (widget.startMs + 30000) * 1000,
                )
                .entries
                .map((e) => e.element),
          ),
          'viewport': [metrics!.size.width, metrics!.size.height],
          'videoStartMs': videoStartMs,
          'videoEndMs': widget.player.state.position.inMilliseconds,
          'videoPlaying': widget.player.state.playing,
          ...metrics!.summarize(),
          'peakActive': peakActive,
          'peakWorkingSetBytes': peakBytes,
          'buildUs': distribution(
            timings.map((e) => e.buildDuration.inMicroseconds),
          ),
          'rasterUs': distribution(
            timings.map((e) => e.rasterDuration.inMicroseconds),
          ),
          'visible': await windowManager.isVisible(),
          'minimized': await windowManager.isMinimized(),
          'processPeakWorkingSetBytes': ProcessInfo.maxRss,
        }),
      );
      coordinator?.dispose();
      renderer?.dispose();
      await widget.player.dispose();
      exit(0);
    } catch (error, stack) {
      await File('${widget.output.path}/error.txt')
          .writeAsString('$error\n$stack');
      exit(1);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        renderer ??= DanmakuWindowRenderer<DensityTag>(
          option: const DanmakuOption(
            fontSize: 25,
            duration: 8,
            safeArea: false,
          ),
          size: size,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        );
        if (coordinator == null) {
          renderer!.reset(widget.startMs * 1000);
          coordinator = DanmakuWindowCoordinator<DensityTag>(
            source: widget.source,
            renderer: renderer!,
            preparePerFrame: widget.perFrame,
            maxCandidatesPerBucket: widget.cap,
            contentOf: (e) => DanmakuContentItem<DensityTag>(
              e.content,
              color: Color(0xff000000 | e.color),
              type: e.mode == 5
                  ? DanmakuItemType.top
                  : e.mode == 4
                  ? DanmakuItemType.bottom
                  : DanmakuItemType.scroll,
              extra: (weight: e.weight, sourceMs: e.progress),
            ),
          );
        }
        metrics ??= DanmakuDensityMetrics(
          input: widget.source.input,
          size: size,
        );
        return RepaintBoundary(
          key: boundary,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Video(controller: widget.video, controls: null),
              DanmakuWindowScreen<DensityTag>(
                renderer: renderer!,
                clock: clock,
                size: size,
                prepareFrame: coordinator!.prepareFrame,
                inputChanges: coordinator!.updates,
                needsPreparation: () => coordinator!.needsPreparation,
                nextPreparationUs: () => coordinator!.nextPreparationUs,
                frameRate: 60,
              ),
            ],
          ),
        );
      },
    ),
  );
}
