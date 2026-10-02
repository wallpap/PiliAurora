import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/pages/danmaku/windows_renderer.dart';
import 'package:pili_aurora/pages/danmaku/windows_screen.dart';

const _videoPath = String.fromEnvironment('DANMAKU_BENCH_VIDEO');
const _outputPath = String.fromEnvironment(
  'DANMAKU_BENCH_OUTPUT',
  defaultValue: 'build/danmaku-benchmark-profile.json',
);
const _repetitions = int.fromEnvironment(
  'DANMAKU_BENCH_REPETITIONS',
  defaultValue: 2,
);
const _option = DanmakuOption(fontSize: 24, duration: 6, massiveMode: true);
const _warmup = Duration(seconds: 3);
const _measurement = Duration(seconds: 5);

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  Player? player;
  VideoController? video;
  if (_videoPath.isNotEmpty) {
    if (!File(_videoPath).existsSync()) {
      throw ArgumentError('Missing video fixture');
    }
    MediaKit.ensureInitialized();
    player = await Player.create();
    video = await VideoController.create(
      player,
      configuration: const VideoControllerConfiguration(hwdec: 'auto-copy'),
    );
    await player.setVolume(0);
    await player.setPlaylistMode(PlaylistMode.single);
    await player.open(const Media(_videoPath));
  }
  runApp(
    MaterialApp(
      home: _Benchmark(
        player: player,
        video: video,
        shutdownSmoke: arguments.contains('--shutdown-smoke'),
      ),
    ),
  );
}

class _Benchmark extends StatefulWidget {
  const _Benchmark({this.player, this.video, this.shutdownSmoke = false});

  final Player? player;
  final VideoController? video;
  final bool shutdownSmoke;

  @override
  State<_Benchmark> createState() => _BenchmarkState();
}

class _BenchmarkState extends State<_Benchmark> {
  final _results = <Map<String, Object?>>[];
  final _frames = <FrameTiming>[];
  DanmakuController<void>? _controller;
  WindowsDanmakuRenderer<void>? _renderer;
  Completer<void>? _ready;
  Timer? _admission;
  bool _prepared = false;
  String _scenario = 'sparse';
  int _case = -1;
  int _sequence = 0;
  int _accepted = 0;
  bool _measuring = false;
  double _addMicros = 0;
  int _addCalls = 0;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  void _onTimings(List<FrameTiming> timings) {
    if (_measuring) _frames.addAll(timings);
  }

  DanmakuContentItem<void> _content(int index) => DanmakuContentItem<void>(
    '预缓冲弹幕 ${_scenario == 'unique' ? index : index % 12}',
    color: const Color(0xFFFFFFFF),
  );

  void _add() {
    final count = _scenario == 'sparse' ? 1 : 4;
    final stopwatch = Stopwatch()..start();
    for (var index = 0; index < count; index++) {
      if (_controller!.addDanmaku(_content(_sequence++))) _accepted++;
    }
    stopwatch.stop();
    if (_measuring) {
      _addMicros += stopwatch.elapsedMicroseconds;
      _addCalls += count;
    }
    if (_prepared) {
      _renderer!.queuePrewarm(
        List.generate(count * 10, (index) => _content(_sequence + index)),
      );
    }
  }

  Future<void> _run() async {
    try {
      if (widget.video != null) {
        await widget.video!.waitUntilFirstFrameRendered.timeout(
          const Duration(seconds: 15),
        );
      }
      if (widget.shutdownSmoke) {
        _ready = Completer<void>();
        setState(() {
          _prepared = true;
          _case++;
        });
        await _ready!.future.timeout(const Duration(seconds: 5));
        _add();
        await Future<void>.delayed(const Duration(seconds: 2));
        stdout.writeln('DANMAKU_SHUTDOWN_SMOKE rendered');
        await _shutdown(0);
        return;
      }
      for (var repetition = 0; repetition < _repetitions; repetition++) {
        for (final scenario in ['sparse', 'repeated', 'unique']) {
          for (final prepared
              in repetition.isEven ? [false, true] : [true, false]) {
            _admission?.cancel();
            _measuring = false;
            _ready = Completer<void>();
            _controller = null;
            _renderer = null;
            _sequence = 0;
            _accepted = 0;
            setState(() {
              _scenario = scenario;
              _prepared = prepared;
              _case++;
            });
            await _ready!.future.timeout(const Duration(seconds: 5));
            _add();
            _admission = Timer.periodic(
              Duration(milliseconds: scenario == 'sparse' ? 500 : 100),
              (_) => _add(),
            );
            await Future<void>.delayed(_warmup);
            _frames.clear();
            _addMicros = 0;
            _addCalls = 0;
            _measuring = true;
            await Future<void>.delayed(_measurement);
            _measuring = false;
            final result = <String, Object?>{
              'repetition': repetition,
              'scenario': scenario,
              'renderer': prepared ? 'prepared' : 'baseline',
              'frames': _frames.length,
              'accepted': _accepted,
              'addMeanUs': _addCalls == 0 ? 0 : _addMicros / _addCalls,
              'build': _summary(_frames.map((frame) => frame.buildDuration)),
              'raster': _summary(_frames.map((frame) => frame.rasterDuration)),
              'total': _summary(_frames.map((frame) => frame.totalSpan)),
              'over16ms': _frames
                  .where(
                    (frame) =>
                        frame.buildDuration.inMicroseconds > 16667 ||
                        frame.rasterDuration.inMicroseconds > 16667,
                  )
                  .length,
              'rssBytes': ProcessInfo.currentRss,
              if (prepared) 'statistics': _renderer!.statistics,
            };
            _results.add(result);
            stdout.writeln('DANMAKU_BENCH ${jsonEncode(result)}');
          }
        }
      }
      _admission?.cancel();
      final output = File(_outputPath);
      await output.parent.create(recursive: true);
      await output.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'video': _videoPath,
          'devicePixelRatio': mounted
              ? MediaQuery.devicePixelRatioOf(context)
              : null,
          'warmupSeconds': _warmup.inSeconds,
          'measurementSeconds': _measurement.inSeconds,
          'results': _results,
        }),
      );
      stdout.writeln('DANMAKU_BENCH_OUTPUT ${output.absolute.path}');
      await _shutdown(0);
    } catch (error, stack) {
      stderr.writeln('$error\n$stack');
      await _shutdown(1);
    }
  }

  Future<void> _shutdown(int code) async {
    _admission?.cancel();
    await widget.player?.dispose();
    if (widget.player != null) {
      await Future<void>.delayed(const Duration(seconds: 6));
    }
    stdout.writeln(
      'DANMAKU_BENCH_COMPLETE code=$code '
      'close the benchmark window manually',
    );
  }

  Map<String, double> _summary(Iterable<Duration> durations) {
    final values =
        durations.map((duration) => duration.inMicroseconds / 1000).toList()
          ..sort();
    double percentile(double fraction) =>
        values.isEmpty ? 0 : values[((values.length - 1) * fraction).round()];
    return {
      'p50Ms': percentile(0.5),
      'p95Ms': percentile(0.95),
      'p99Ms': percentile(0.99),
      'maxMs': percentile(1),
    };
  }

  void _created(DanmakuController<void> controller) {
    _controller = controller;
    _ready?.complete();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF205080),
    body: LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (widget.video != null)
              RepaintBoundary(child: SimpleVideo(controller: widget.video!)),
            if (_case >= 0)
              if (_prepared)
                WindowsDanmakuScreen<void>(
                  key: ValueKey(_case),
                  option: _option,
                  size: size,
                  opacity: 0.5,
                  createdRenderer: (renderer) {
                    _renderer = renderer;
                    _created(renderer.controller);
                  },
                )
              else
                Opacity(
                  opacity: 0.5,
                  child: DanmakuScreen<void>(
                    key: ValueKey(_case),
                    option: _option,
                    size: size,
                    createdController: _created,
                  ),
                ),
            Align(
              alignment: Alignment.bottomLeft,
              child: Text(
                '$_scenario / ${_prepared ? 'prepared' : 'baseline'} / $_case',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        );
      },
    ),
  );

  @override
  void dispose() {
    _admission?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }
}
