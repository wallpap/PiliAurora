import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FramePhase;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/pages/danmaku/interaction.dart';
import 'package:pili_aurora/pages/danmaku/live_layer.dart';
import 'package:pili_aurora/pages/danmaku/live_queue.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/pages/danmaku/window_screen.dart';
import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';
import 'package:window_manager/window_manager.dart';
import 'package:win32/win32.dart'
    show QueryPerformanceCounter, QueryPerformanceFrequency;

/// 独立窗口测量生产弹幕；可选本地视频用于检查纹理合成负载。
Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows) throw UnsupportedError('Windows probe');
  final report = File(
    arguments.isEmpty
        ? 'doc/dev/diagnostics/windows-danmaku-validation/production.json'
        : arguments.first,
  );
  await report.parent.create(recursive: true);
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1280, 720),
      center: true,
      title: 'PiliAurora danmaku frame probe',
      alwaysOnTop: true,
    ),
  );
  // Windows 隐藏启动时，首次 ShowWindow 会沿用启动参数；确认真正显示后再测量。
  await windowManager.show();
  for (var attempt = 0; attempt < 3; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (await windowManager.isVisible()) break;
    await windowManager.show();
  }
  await windowManager.focus();
  if (!await windowManager.isVisible()) {
    await report.writeAsString(
      jsonEncode({'passed': false, 'error': 'windowHidden'}),
    );
    exit(1);
  }

  VideoController? video;
  if (arguments.length > 1) {
    final media = File(arguments[1]);
    if (!media.existsSync()) throw ArgumentError('需要可读取的本地视频文件');
    MediaKit.ensureInitialized();
    final player = await Player.create(
      configuration: const PlayerConfiguration(
        options: {'ao': 'null', 'video-sync': 'display-resample'},
      ),
    );
    video = await VideoController.create(
      player,
      configuration: const VideoControllerConfiguration(hwdec: 'd3d11va'),
    );
    await player.setPlaylistMode(PlaylistMode.loop);
    await player.open(Media(media.absolute.path));
  }
  runApp(
    MaterialApp(
      home: _Probe(report: report, video: video),
    ),
  );
}

class _Clock implements PlaybackMediaClock {
  final _events = StreamController<PlaybackMediaAnchor?>.broadcast();
  final _start = Timeline.now;

  @override
  PlaybackMediaAnchor get currentMediaAnchor => PlaybackMediaAnchor(
    positionUs: 0,
    observedAtUs: _start,
    effectiveRate: 1,
    advancing: true,
    ready: true,
    continuity: 0,
    validForUs: 120000000,
  );

  // 空流会立即触发 onDone，生产组件会将其解释为媒体时钟失效。
  @override
  Stream<PlaybackMediaAnchor?> get mediaAnchors => _events.stream;

  Future<void> close() => _events.close();
}

class _Probe extends StatefulWidget {
  const _Probe({required this.report, this.video});
  final File report;
  final VideoController? video;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  int _stage = 0;
  bool _measuring = false;
  _Clock _clock = _Clock();
  final _results = <Map<String, Object?>>[];
  final _frames = <Map<String, Object?>>[];
  final _timings = <FrameTiming>[];
  StreamController<LiveDanmakuMessage<void>>? _messages;
  DanmakuWindowRenderer<void>? _renderer;
  DanmakuInteractionHandle<void> Function()? _interaction;
  bool get _live => _stage >= 2;
  int get _count => _stage.isEven ? 12 : 60;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    WidgetsBinding.instance.addPostFrameCallback(_sample);
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  void _onTimings(List<FrameTiming> timings) {
    _timings.addAll(timings);
  }

  void _sample(Duration _) {
    if (!mounted) return;
    if (_measuring) {
      final items =
          _interaction?.call().snapshot ??
          _renderer?.interaction.snapshot ??
          [];
      final moving = items.where((item) => item.text.startsWith('scroll '));
      final item = moving.firstOrNull;
      final size = MediaQuery.sizeOf(context);
      _frames.add({
        'frameNumber':
            SchedulerBinding.instance.platformDispatcher.frameData.frameNumber,
        'targetUs': SchedulerBinding
            .instance
            .currentSystemFrameTimeStamp
            .inMicroseconds,
        'deliveredUs': Timeline.now,
        'active': items.length,
        'identity': item?.text,
        'x': item?.bounds.left,
        // 直播按像素位移反推运动时间，点播直接读取同帧 renderer 时间。
        'positionUs': _live
            ? item == null
                  ? null
                  : ((size.width - item.bounds.left) *
                            120000000 /
                            (size.width + item.bounds.width))
                        .round()
            : _renderer?.presentationTimeUs,
      });
    }
    // 观察已有帧，不主动请求额外帧，以免掩盖生产调度器的漏帧。
    WidgetsBinding.instance.addPostFrameCallback(_sample);
  }

  Future<void> _run() async {
    try {
      if (widget.video != null && _stage == 0) {
        await widget.video!.waitUntilFirstFrameRendered.timeout(
          const Duration(seconds: 20),
        );
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      if (_live) {
        for (var i = 0; i < _count; i++) {
          _messages!.add(
            LiveDanmakuMessage<void>(
              identity: i,
              receivedAtUs: Timeline.now,
              text: _text(i),
              type: _type(i),
            ),
          );
        }
      }
      await Future<void>.delayed(const Duration(seconds: 3));
      _frames.clear();
      _timings.clear();
      final calibration = _clockCalibration();
      final windowStates = <Map<String, Object?>>[];
      _measuring = true;
      for (var second = 0; second < 10; second++) {
        windowStates.add({
          'visible': await windowManager.isVisible(),
          'minimized': await windowManager.isMinimized(),
          'focused': await windowManager.isFocused(),
          'alwaysOnTop': await windowManager.isAlwaysOnTop(),
        });
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      _measuring = false;
      // Windows 的 FrameTiming 会批量交付，等待末批后按帧编号关联。
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      if (!mounted) return;
      final refresh = View.of(context).display.refreshRate;
      final gaps = [
        for (var i = 1; i < _frames.length; i++)
          (_frames[i]['targetUs']! as int) -
              (_frames[i - 1]['targetUs']! as int),
      ];
      final fps = gaps.isEmpty
          ? 0.0
          : gaps.length * 1000000 / gaps.reduce((a, b) => a + b);
      final longGaps = gaps.where((gap) => gap > 1500000 / refresh).length;
      final active = _frames.map((frame) => frame['active']! as int).toList();
      final windowValid = windowStates.every(
        (state) =>
            state['visible'] == true &&
            state['minimized'] == false &&
            state['alwaysOnTop'] == true,
      );
      final passed =
          refresh > 0 &&
          windowValid &&
          active.isNotEmpty &&
          active.every((count) => count > 0) &&
          fps >= refresh * .95 &&
          longGaps < gaps.length * .01;
      _results.add({
        'mode': _live ? 'live' : 'point',
        'requestedCount': _count,
        'refreshHz': refresh,
        'clockCalibration': calibration,
        'windowStates': windowStates,
        'passed': passed,
        'fps': fps,
        'activeMin': active.isEmpty ? 0 : active.reduce(math.min),
        'activeMax': active.isEmpty ? 0 : active.reduce(math.max),
        'gapUs': _distribution(gaps),
        'longGaps': longGaps,
        'buildUs': _distribution(
          _timings.map((t) => t.buildDuration.inMicroseconds).toList(),
        ),
        'rasterUs': _distribution(
          _timings.map((t) => t.rasterDuration.inMicroseconds).toList(),
        ),
        'frames': List.of(_frames),
        'timings': [
          for (final t in _timings)
            {
              'vsyncUs': t.timestampInMicroseconds(FramePhase.vsyncStart),
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
      await _writeReport();
      if (_stage == 3) {
        await windowManager.setAlwaysOnTop(false);
        exit(_results.every((r) => r['passed'] == true) ? 0 : 1);
      }
      final oldRenderer = _renderer;
      final oldClock = _clock;
      _renderer = null;
      _interaction = null;
      await _messages?.close();
      _messages = null;
      _clock = _Clock();
      setState(() => _stage++);
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        oldRenderer?.dispose();
        await oldClock.close();
        await _run();
      });
    } catch (error) {
      _measuring = false;
      await _writeReport(error: error.runtimeType.toString());
      await windowManager.setAlwaysOnTop(false);
      exit(1);
    }
  }

  Future<void> _writeReport({String? error}) => widget.report.writeAsString(
    jsonEncode({
      'passed':
          error == null &&
          _results.length == 4 &&
          _results.every((r) => r['passed'] == true),
      'videoBackground': widget.video != null,
      'stages': _results,
      'error': ?error,
    }),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Column(
      children: [
        Text(
          'Windows ${_live ? 'live' : 'point'} / $_count / follow display',
          style: const TextStyle(color: Colors.white),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              const option = DanmakuOption(
                fontSize: 22,
                duration: 120,
                staticDuration: 120,
                massiveMode: true,
                safeArea: false,
              );
              late final Widget layer;
              if (_live) {
                _messages ??=
                    StreamController<LiveDanmakuMessage<void>>.broadcast(
                      sync: true,
                    );
                layer = LiveDanmakuLayer<void>(
                  key: ValueKey(_stage),
                  messages: _messages!.stream,
                  running: true,
                  visible: true,
                  option: option,
                  size: size,
                  createdInteraction: (get, _) => _interaction = get,
                );
              } else {
                _renderer ??= DanmakuWindowRenderer<void>(
                  option: option,
                  size: size,
                  devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                );
                layer = DanmakuWindowScreen<void>(
                  key: ValueKey(_stage),
                  renderer: _renderer!,
                  clock: _clock,
                  size: size,
                  prepareFrame: (renderer, position, {required effectiveRate}) {
                    if (renderer.validUntilUs != renderer.validFromUs) return;
                    renderer.prepare(
                      [
                        for (var i = 0; i < _count; i++)
                          DanmakuWindowContent<void>(
                            i,
                            renderer.validFromUs,
                            DanmakuContentItem<void>(_text(i), type: _type(i)),
                          ),
                      ],
                      generation: renderer.generation,
                      preparedUntilUs: 120000000,
                    );
                  },
                );
              }
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (widget.video != null)
                    Video(controller: widget.video!, controls: null),
                  layer,
                ],
              );
            },
          ),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }
}

DanmakuItemType _type(int index) => switch (index % 6) {
  0 => DanmakuItemType.top,
  1 => DanmakuItemType.bottom,
  _ => DanmakuItemType.scroll,
};

String _text(int index) => '${_type(index).name} Windows 弹幕 $index';

Map<String, Object?> _distribution(List<int> values) {
  if (values.isEmpty) return {'count': 0};
  values.sort();
  return {
    'count': values.length,
    'p95': values[(values.length * .95).ceil() - 1],
    'p99': values[(values.length * .99).ceil() - 1],
    'max': values.last,
  };
}

Map<String, int> _clockCalibration() {
  final counter = calloc<Int64>();
  final frequency = calloc<Int64>();
  try {
    QueryPerformanceFrequency(frequency);
    QueryPerformanceCounter(counter);
    final before = counter.value;
    final timelineUs = Timeline.now;
    QueryPerformanceCounter(counter);
    return {
      'qpcBefore': before,
      'qpcAfter': counter.value,
      'frequency': frequency.value,
      'timelineUs': timelineUs,
    };
  } finally {
    calloc
      ..free(counter)
      ..free(frequency);
  }
}
