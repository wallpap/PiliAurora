import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FramePhase;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/render_guard.dart';
import 'package:pili_aurora/pages/danmaku/windows_renderer.dart';
import 'package:pili_aurora/pages/danmaku/windows_screen.dart';
import 'package:pili_aurora/plugin/pl_player/utils/video_output_size.dart';
import 'package:pili_aurora/services/diagnostics/player_diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/process_metrics.dart';
import 'package:pili_aurora/utils/danmaku_utils.dart';

// 所有实验参数在运行时传入，同一 Profile 构建可用于独立进程对照。
late final PlaybackBenchmarkConfig _config;
late final double _fixtureDevicePixelRatio;
String get _videoPath => _config.video;
String get _danmakuPath => _config.danmaku;
String get _outputPath => _config.output;
int get _startMs => _config.startMs;
int get _warmupSeconds => _config.warmupSeconds;
int get _measurementSeconds => _config.measurementSeconds;
int get _repetitions => _config.repetitions;
bool get _fitVideoOutputToViewport => true;
String get _hwdec => _config.hwdec;

class PlaybackBenchmarkConfig {
  PlaybackBenchmarkConfig(List<String> arguments) {
    final values = <String, String>{};
    const supported = {
      'video',
      'danmaku',
      'audio',
      'output',
      'start-ms',
      'warmup-seconds',
      'measurement-seconds',
      'repetitions',
      'cache-mib',
      'cache-entries',
      'telemetry-ms',
      'renderer',
      'kind',
      'hwdec',
      'prewarm',
      'label',
      'opacity',
      'composition',
      'include-special',
      'overlay',
      'static-only',
    };
    for (final argument in arguments) {
      final split = argument.indexOf('=');
      if (!argument.startsWith('--') || split < 3) {
        throw ArgumentError('Expected --name=value');
      }
      final key = argument.substring(2, split);
      if (!supported.contains(key) || values.containsKey(key)) {
        throw ArgumentError('Unknown or duplicate benchmark option: $key');
      }
      values[key] = argument.substring(split + 1);
    }
    video = values['video'] ?? '';
    danmaku = values['danmaku'] ?? '';
    audio = values['audio'] ?? '';
    output = values['output'] ?? 'build/playback-benchmark.json';
    label = values['label'] ?? 'local';
    hwdec = values['hwdec'] ?? 'auto-copy';
    renderer = values['renderer'] ?? 'prepared';
    kind = values['kind'] ?? 'stress';
    if (!{'prepared', 'baseline', 'both'}.contains(renderer) ||
        !{'stress', 'lifecycle', 'endurance'}.contains(kind)) {
      throw ArgumentError('Invalid renderer or experiment kind');
    }
    if (kind != 'stress' && renderer != 'prepared') {
      throw ArgumentError('Lifecycle/endurance requires the prepared renderer');
    }
    int number(String key, int fallback, int min, int max) {
      final value = int.tryParse(values[key] ?? '$fallback');
      if (value == null || value < min || value > max) {
        throw ArgumentError('$key must be in [$min, $max]');
      }
      return value;
    }

    startMs = number('start-ms', 40000, 0, 86400000);
    warmupSeconds = number('warmup-seconds', 3, 1, 60);
    measurementSeconds = number('measurement-seconds', 10, 1, 1800);
    repetitions = number('repetitions', 2, 1, 20);
    cacheMiB = number('cache-mib', 16, 1, 128);
    cacheEntries = number('cache-entries', 512, 1, 8192);
    telemetryMs = number('telemetry-ms', 250, 0, 5000);
    if (telemetryMs > 0 && telemetryMs < 100) {
      throw ArgumentError('Telemetry interval must be zero or >=100 ms');
    }
    final prewarmValue = values['prewarm'] ?? 'true';
    if (!{'true', 'false'}.contains(prewarmValue)) {
      throw ArgumentError('prewarm must be true or false');
    }
    prewarm = prewarmValue == 'true';
    opacity = double.tryParse(values['opacity'] ?? '0.5') ?? double.nan;
    if (!opacity.isFinite || opacity <= 0 || opacity > 1) {
      throw ArgumentError('opacity must be in (0, 1]');
    }
    composition = values['composition'] ?? 'auto';
    if (!{'auto', 'reference-group'}.contains(composition)) {
      throw ArgumentError('Invalid composition');
    }
    bool flag(String name, {bool fallback = true}) {
      final value = values[name] ?? '$fallback';
      if (!{'true', 'false'}.contains(value)) {
        throw ArgumentError('$name must be true or false');
      }
      return value == 'true';
    }

    includeSpecial = flag('include-special');
    overlay = flag('overlay');
    staticOnly = flag('static-only', fallback: false);
    if (kind == 'endurance' && telemetryMs != 0) {
      throw ArgumentError(
        'Endurance requires telemetry-ms=0: sample externally',
      );
    }
  }

  late final String video, danmaku, audio, output, label, hwdec, renderer, kind;
  late final int startMs, warmupSeconds, measurementSeconds, repetitions;
  late final int cacheMiB, cacheEntries, telemetryMs;
  late final bool prewarm, includeSpecial, overlay, staticOnly;
  late final double opacity;
  late final String composition;

  Map<String, Object?> toJson() => {
    'label': label,
    'kind': kind,
    'renderer': renderer,
    'cacheMiB': cacheMiB,
    'cacheEntries': cacheEntries,
    'telemetryMs': telemetryMs,
    'prewarm': prewarm,
    'opacity': opacity,
    'composition': composition,
    'includeSpecial': includeSpecial,
    'overlay': overlay,
    'staticOnly': staticOnly,
    'frameTimingsRecorded': kind != 'endurance',
    'requestedHwdec': hwdec,
    'startMs': startMs,
    'warmupSeconds': warmupSeconds,
    'measurementSeconds': measurementSeconds,
    'repetitions': repetitions,
    'audioIncluded': audio.isNotEmpty,
  };
}

/// 将自然循环折算为累计媒体进度；小幅通知抖动不作为回退 seek。
({int milliseconds, bool wrapped, bool unexpectedBackwards})
playbackProgressDelta(
  int previous,
  int current,
  int duration,
) {
  final delta = current - previous;
  if (delta >= 0) {
    return (milliseconds: delta, wrapped: false, unexpectedBackwards: false);
  }
  if (delta >= -500) {
    return (milliseconds: 0, wrapped: false, unexpectedBackwards: false);
  }
  if (duration > 0 && previous >= duration - 2000 && current <= 2000) {
    return (
      milliseconds: duration - previous + current,
      wrapped: true,
      unexpectedBackwards: false,
    );
  }
  return (milliseconds: 0, wrapped: false, unexpectedBackwards: true);
}

/// 累计进度使用单调高水位，避免回退通知恢复时重复计数。
class PlaybackProgressAccumulator {
  PlaybackProgressAccumulator(this._position);
  int _position;
  int milliseconds = 0;
  int wraps = 0;
  int unexpectedBackwards = 0;

  void setPosition(int position) => _position = position;

  void observe(int position, int duration) {
    if (position < _position && _position - position <= 500) return;
    final delta = playbackProgressDelta(_position, position, duration);
    milliseconds += delta.milliseconds;
    if (delta.wrapped) wraps++;
    if (delta.unexpectedBackwards) unexpectedBackwards++;
    _position = position;
  }
}

const _option = DanmakuOption(fontSize: 24, duration: 6, massiveMode: true);
const _maxActiveDanmaku = 600;
const _maxActiveSpecialDanmaku = 32;

String playbackFixtureUri(String video, String audio) => audio.isEmpty
    ? video
    : 'edl://!no_chapters;'
          '%${utf8.encode(video).length}%$video;'
          '!new_stream;!no_chapters;'
          '%${utf8.encode(audio).length}%$audio';

class _FixtureEntry {
  const _FixtureEntry(this.progress, this.content, this.mode);

  final int progress;
  final DanmakuContentItem<void> content;
  final int mode;
}

Future<void> main(List<String> arguments) async {
  _config = PlaybackBenchmarkConfig(arguments);
  WidgetsFlutterBinding.ensureInitialized();
  if (_videoPath.isEmpty || _danmakuPath.isEmpty) {
    throw ArgumentError(
      '--video and --danmaku are required',
    );
  }
  final videoFile = File(_videoPath);
  final danmakuFile = File(_danmakuPath);
  if (!videoFile.existsSync()) throw ArgumentError('Missing video fixture');
  if (!danmakuFile.existsSync()) throw ArgumentError('Missing danmaku fixture');
  if (_config.audio.isNotEmpty && !File(_config.audio).existsSync()) {
    throw ArgumentError('Missing audio fixture');
  }

  _fixtureDevicePixelRatio =
      WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
  final loadWatch = Stopwatch()..start();
  final reply = DmSegMobileReply.fromBuffer(await danmakuFile.readAsBytes());
  final entries = <_FixtureEntry>[];
  final modeCounts = <int, int>{};
  var specialCount = 0;
  var colorfulCount = 0;
  var maxProgress = 0;
  for (final elem in reply.elems) {
    modeCounts[elem.mode] = (modeCounts[elem.mode] ?? 0) + 1;
    if (elem.progress > maxProgress) maxProgress = elem.progress;
    if (elem.colorful == DmColorfulType.VipGradualColor) colorfulCount++;
    try {
      final content = _toContent(elem);
      if (content == null) continue;
      if (elem.mode == 7) specialCount++;
      entries.add(_FixtureEntry(elem.progress, content, elem.mode));
    } catch (_) {
      // 单条高级弹幕解析失败时跳过，保持压力测试继续进行。
    }
  }
  entries.sort((a, b) => a.progress.compareTo(b.progress));
  loadWatch.stop();
  final fixture = <String, Object?>{
    'danmakuBytes': danmakuFile.lengthSync(),
    'videoBytes': videoFile.lengthSync(),
    'sourceElements': reply.elems.length,
    'renderableEntries': entries.length,
    'durationProgressMs': maxProgress,
    'modeCounts': modeCounts.map((key, value) => MapEntry('$key', value)),
    'specialMode7': specialCount,
    'colorfulCount': colorfulCount,
    'conversionMs': loadWatch.elapsedMicroseconds / 1000,
    'stressStartMs': _startMs,
    'warmupSeconds': _warmupSeconds,
    'measurementSeconds': _measurementSeconds,
  };

  MediaKit.ensureInitialized();
  final player = await Player.create();
  final video = await VideoController.create(
    player,
    configuration: VideoControllerConfiguration(hwdec: _hwdec),
  );
  await player.setVolume(0);
  await player.setPlaylistMode(PlaylistMode.single);
  // 与点播 FileSource 相同，用 UTF-8 字节长度构造分离音视频 EDL。
  await player.open(Media(playbackFixtureUri(_videoPath, _config.audio)));

  runApp(
    MaterialApp(
      home: _StressBenchmark(
        player: player,
        video: video,
        entries: entries,
        fixture: fixture,
      ),
    ),
  );
}

DanmakuContentItem<void>? _toContent(DanmakuElem elem) {
  if (elem.mode == 7) {
    final content = SpecialDanmakuContentItem<void>.fromList(
      DmUtils.decimalToColor(elem.color),
      elem.fontsize > 0 ? elem.fontsize.toDouble() : _option.fontSize,
      jsonDecode(elem.content.replaceAll('\n', '\\n')),
    );
    if (!DanmakuRenderGuard.canRasterizeSpecial(
      content,
      _fixtureDevicePixelRatio,
      _option.strokeWidth,
      _option.fontWeight,
    )) {
      return null;
    }
    return content;
  }
  return DanmakuContentItem<void>(
    elem.content,
    color: DmUtils.decimalToColor(elem.color),
    type: DmUtils.getPosition(elem.mode),
    isColorful: elem.colorful == DmColorfulType.VipGradualColor,
  );
}

class _StressBenchmark extends StatefulWidget {
  const _StressBenchmark({
    required this.player,
    required this.video,
    required this.entries,
    required this.fixture,
  });

  final Player player;
  final VideoController video;
  final List<_FixtureEntry> entries;
  final Map<String, Object?> fixture;

  @override
  State<_StressBenchmark> createState() => _StressBenchmarkState();
}

class _StressBenchmarkState extends State<_StressBenchmark> {
  final _results = <Map<String, Object?>>[];
  final _frames = <FrameTiming>[];
  final _telemetrySamples = <Map<String, Object?>>[];
  final _processMetrics = ProcessMetrics();
  DanmakuController<void>? _controller;
  WindowsDanmakuRenderer<void>? _renderer;
  Completer<void>? _ready;
  Timer? _admission;
  Timer? _telemetryTimer;
  final _wallClock = Stopwatch()..start();
  int _mediaStartMs = 0;
  int _lastPositionMs = 0;
  final _mediaProgress = PlaybackProgressAccumulator(0);
  int get _mediaProgressMs => _mediaProgress.milliseconds;
  int get _mediaWraps => _mediaProgress.wraps;
  int get _unexpectedBackwards => _mediaProgress.unexpectedBackwards;
  bool _playerDisposed = false;
  int _outerActiveRejections = 0;
  int _outerSpecialRejections = 0;
  int _addMicros = 0;
  int _addCalls = 0;
  double _viewportScale = 1;
  bool _overlayEnabled = true;
  int _measurementStartMicros = 0;
  int _measurementEndMicros = 0;
  int _sampleMicros = 0;
  int _sampleCalls = 0;
  String _phase = 'loading';
  bool _prepared = false;
  int _case = -1;
  int _cursor = 0;
  int _lastPrewarmPosition = -1;
  int _prewarmQueued = 0;
  int _accepted = 0;
  int _rejected = 0;
  int _specialAccepted = 0;
  bool _measuring = false;
  int _videoOutputRequests = 0;
  VideoOutputSize? _videoOutputSize;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  void _onTimings(List<FrameTiming> timings) {
    if (_measuring && _config.kind != 'endurance') {
      _frames.addAll(
        timings.where(
          (frame) =>
              frame.timestampInMicroseconds(FramePhase.buildStart) >=
              _measurementStartMicros,
        ),
      );
    }
  }

  String? _property(String name) => readMpvProperty(widget.player, name);

  void _captureTelemetry() {
    final state = widget.player.state;
    final watch = Stopwatch()..start();
    _telemetrySamples.add({
      'wallElapsedMs': _wallClock.elapsedMilliseconds,
      'phase': _phase,
      'player': {
        'playing': state.playing,
        'buffering': state.buffering,
        'positionMs': state.position.inMilliseconds,
        'durationMs': state.duration.inMilliseconds,
        'bufferMs': state.buffer.inMilliseconds,
        'rate': state.rate,
        'width': state.width,
        'height': state.height,
        for (final property in [
          'hwdec',
          'hwdec-current',
          'video-codec',
          'video-format',
          'video-params',
          'estimated-vf-fps',
          'decoder-frame-drop-count',
          'frame-drop-count',
          'demuxer-cache-duration',
          'demuxer-cache-time',
          'video-bitrate',
          'audio-codec',
          'audio-bitrate',
        ])
          property: _property(property),
      },
      'process': _processMetrics.sample(),
      if (_prepared) 'renderer': _renderer?.statistics,
    });
    watch.stop();
    _sampleMicros += watch.elapsedMicroseconds;
    _sampleCalls++;
    _telemetrySamples.last['sampleMicros'] = watch.elapsedMicroseconds;
  }

  int get _activeBaseline {
    final controller = _controller;
    if (controller == null) return 0;
    return controller.scrollDanmaku.fold<int>(
          0,
          (sum, track) => sum + track.length,
        ) +
        controller.staticDanmaku.whereType<DanmakuItem<void>>().length +
        controller.specialDanmaku.length;
  }

  int get _activeSpecial => _controller?.specialDanmaku.length ?? 0;

  int _lowerBound(int progress) {
    var low = 0;
    var high = widget.entries.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (widget.entries[mid].progress < progress) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  void _queuePrewarm(int position) {
    final renderer = _renderer;
    if (!_config.prewarm ||
        !_overlayEnabled ||
        !_prepared ||
        renderer == null ||
        position - _lastPrewarmPosition < 500) {
      return;
    }
    _lastPrewarmPosition = position;
    final end = position + 2000;
    final contents = <DanmakuContentItem<void>>[];
    for (
      var index = _cursor;
      index < widget.entries.length &&
          widget.entries[index].progress <= end &&
          contents.length < 64;
      index++
    ) {
      final entry = widget.entries[index];
      if (entry.progress > position &&
          entry.mode != 7 &&
          (!_config.staticOnly || entry.mode == 4 || entry.mode == 5)) {
        contents.add(entry.content);
      }
    }
    renderer.queuePrewarm(contents);
    _prewarmQueued += contents.length;
  }

  void _admitUntil(int position) {
    _queuePrewarm(position);
    final controller = _controller;
    if (controller == null) return;
    while (_cursor < widget.entries.length &&
        widget.entries[_cursor].progress <= position) {
      final entry = widget.entries[_cursor++];
      if (entry.progress < _mediaStartMs ||
          (!_config.includeSpecial && entry.mode == 7) ||
          (_config.staticOnly && entry.mode != 4 && entry.mode != 5)) {
        continue;
      }
      if (_activeBaseline >= _maxActiveDanmaku) {
        _outerActiveRejections++;
        _rejected++;
        continue;
      }
      if (entry.mode == 7 && _activeSpecial >= _maxActiveSpecialDanmaku) {
        _outerSpecialRejections++;
        _rejected++;
        continue;
      }
      final stopwatch = Stopwatch()..start();
      final accepted = controller.addDanmaku(entry.content);
      stopwatch.stop();
      if (_measuring) {
        _addMicros += stopwatch.elapsedMicroseconds;
        _addCalls++;
      }
      if (accepted) {
        _accepted++;
        if (entry.mode == 7) _specialAccepted++;
      } else {
        _rejected++;
      }
    }
  }

  void _startAdmission(int startMs) {
    _admission?.cancel();
    _mediaStartMs = startMs;
    _cursor = _lowerBound(startMs);
    _lastPositionMs = startMs;
    _mediaProgress.setPosition(startMs);
    _lastPrewarmPosition = -1;
    _admission = Timer.periodic(const Duration(milliseconds: 20), (_) {
      final state = widget.player.state;
      final controller = _controller;
      if (controller == null) return;
      if (!state.playing || state.buffering) {
        if (controller.isRunning()) controller.pause();
        return;
      }
      final position = state.position.inMilliseconds;
      _mediaProgress.observe(position, state.duration.inMilliseconds);
      if (position < _lastPositionMs - 500) {
        // 循环/回退 seek 不重放积压弹幕。
        controller.clear();
        _mediaStartMs = position;
        _cursor = _lowerBound(position);
        _lastPrewarmPosition = -1;
      }
      _lastPositionMs = position;
      if (!_overlayEnabled) {
        if (controller.isRunning()) controller.pause();
        return;
      }
      if (!controller.isRunning()) controller.resume();
      _admitUntil(position);
    });
  }

  Future<void> _seek(int positionMs) async {
    _admission?.cancel();
    _controller?.pause();
    _controller?.clear();
    await widget.player.pause();
    await widget.player.seek(Duration(milliseconds: positionMs));
    final wait = Stopwatch()..start();
    while ((widget.player.state.position.inMilliseconds - positionMs).abs() >
            500 ||
        _property('seeking') == 'yes') {
      if (wait.elapsed > const Duration(seconds: 10)) {
        throw StateError('Seek did not settle at $positionMs ms');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _startAdmission(positionMs);
    await widget.player.play();
    _controller?.resume();
  }

  Future<void> _newCase(bool prepared) async {
    _admission?.cancel();
    await widget.player.pause();
    _ready = Completer<void>();
    _controller = null;
    _renderer = null;
    _accepted = _rejected = _specialAccepted = _prewarmQueued = 0;
    _outerActiveRejections = _outerSpecialRejections = 0;
    _viewportScale = 1;
    _overlayEnabled = _config.overlay;
    setState(() {
      _prepared = prepared;
      _case++;
    });
    await _ready!.future.timeout(const Duration(seconds: 5));
    await _seek(_startMs);
    await Future<void>.delayed(Duration(seconds: _warmupSeconds));
  }

  Future<void> _measure(String phase, int seconds, {int? repetition}) async {
    setState(() => _phase = phase);
    stdout.writeln('PLAYBACK_BENCH_BEGIN $phase');
    await WidgetsBinding.instance.endOfFrame;
    _measurementStartMicros =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    _measurementEndMicros = 0;
    _frames.clear();
    _telemetrySamples.clear();
    _processMetrics.reset();
    _sampleMicros = _sampleCalls = _addMicros = _addCalls = 0;
    final acceptedBefore = _accepted;
    final rejectedBefore = _rejected;
    final specialBefore = _specialAccepted;
    final outerActiveBefore = _outerActiveRejections;
    final outerSpecialBefore = _outerSpecialRejections;
    final prewarmBefore = _prewarmQueued;
    final statsBefore = _renderer?.statistics;
    final positionBefore = widget.player.state.position.inMilliseconds;
    final expectedPlaying = widget.player.state.playing;
    final progressBefore = _mediaProgressMs;
    final wrapsBefore = _mediaWraps;
    final backwardsBefore = _unexpectedBackwards;
    _measuring = true;
    if (_config.telemetryMs > 0) {
      _captureTelemetry();
      _telemetryTimer = Timer.periodic(
        Duration(milliseconds: _config.telemetryMs),
        (_) => _captureTelemetry(),
      );
    }
    await Future<void>.delayed(Duration(seconds: seconds));
    _telemetryTimer?.cancel();
    _telemetryTimer = null;
    final positionAfter = widget.player.state.position.inMilliseconds;
    final progressAfter = _mediaProgressMs;
    final wrapsAfter = _mediaWraps;
    final backwardsAfter = _unexpectedBackwards;
    final statsAfter = _renderer?.statistics;
    final acceptedAfter = _accepted;
    final rejectedAfter = _rejected;
    final specialAfter = _specialAccepted;
    final outerActiveAfter = _outerActiveRejections;
    final outerSpecialAfter = _outerSpecialRejections;
    final prewarmAfter = _prewarmQueued;
    final addCalls = _addCalls;
    final addMicros = _addMicros;
    _measurementEndMicros =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    // FrameTiming 按批次送达。等尾批次，并按引擎时间戳裁剪，避免混入下一阶段。
    if (_config.kind != 'endurance') {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    _measuring = false;
    _frames.removeWhere(
      (frame) =>
          frame.timestampInMicroseconds(FramePhase.buildStart) >
          _measurementEndMicros,
    );
    final result = <String, Object?>{
      'phase': phase,
      'repetition': repetition,
      'renderer': _prepared ? 'prepared' : 'baseline',
      'frames': _frames.length,
      'frameTimingsRecorded': _config.kind != 'endurance',
      'mediaProgressMs': progressAfter - progressBefore,
      'mediaWraps': wrapsAfter - wrapsBefore,
      'unexpectedBackwards': backwardsAfter - backwardsBefore,
      'durationSeconds': seconds,
      'positionStartMs': positionBefore,
      'expectedPlaying': expectedPlaying,
      'replayWindowValid':
          _config.kind == 'endurance' && !phase.startsWith('endurance-')
          ? null
          : expectedPlaying
          ? (_config.kind == 'endurance' && phase.startsWith('endurance-')
                ? (progressAfter - progressBefore - seconds * 1000).abs() <=
                          1000 &&
                      backwardsAfter == backwardsBefore
                : (positionAfter - positionBefore - seconds * 1000).abs() <=
                      600)
          : (positionAfter - positionBefore).abs() <= 300,
      'positionEndMs': positionAfter,
      'accepted': acceptedAfter - acceptedBefore,
      'rejected': rejectedAfter - rejectedBefore,
      'acceptedIncludingWarmup': acceptedAfter,
      'specialAccepted': specialAfter - specialBefore,
      'outerActiveRejections': outerActiveAfter - outerActiveBefore,
      'outerSpecialRejections': outerSpecialAfter - outerSpecialBefore,
      'prewarmQueued': prewarmAfter - prewarmBefore,
      'meanAddMicros': addCalls == 0 ? null : addMicros / addCalls,
      'telemetryMeanMicros': _sampleCalls == 0
          ? null
          : _sampleMicros / _sampleCalls,
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
      'processAtEnd': _processMetrics.sample(),
      'videoSourceSize': {
        'width': widget.player.state.width,
        'height': widget.player.state.height,
      },
      'videoOutputSize': _videoOutputSize == null
          ? null
          : {
              'width': _videoOutputSize!.width,
              'height': _videoOutputSize!.height,
            },
      'videoOutputRequests': _videoOutputRequests,
      'activeHwdec': _property('hwdec-current'),
      'statisticsBefore': statsBefore,
      'statistics': statsAfter,
      'telemetrySamples': List.of(_telemetrySamples),
    };
    _results.add(result);
    stdout.writeln(
      'PLAYBACK_BENCH_PHASE ${jsonEncode({
        for (final entry in result.entries)
          if (entry.key != 'telemetrySamples') entry.key: entry.value,
      })}',
    );
  }

  Future<void> _runLifecycle() async {
    await _newCase(true);
    await _measure('dense-playback', _measurementSeconds);
    _admission?.cancel();
    await widget.player.pause();
    _controller!.pause();
    final pauseTick = _renderer!.tick;
    await _measure('paused', 3);
    _results.last['pauseTickStable'] = _renderer!.tick == pauseTick;
    await widget.player.play();
    _controller!.resume();
    _startAdmission(widget.player.state.position.inMilliseconds);
    await _measure('resumed', 5);
    await _seek(120000);
    await _measure('seek-forward', 5);
    await _seek(_startMs);
    await _measure('seek-backward', 5);
    // 只模拟播放器可获得的视口尺寸，不改变系统 DPI/窗口状态。
    setState(() => _viewportScale = 0.6);
    await _measure('small-viewport', 4);
    setState(() => _viewportScale = 1);
    await _measure('restored-viewport', 4);
    _admission?.cancel();
    _controller!.pause();
    setState(() => _overlayEnabled = false);
    await _measure('overlay-disabled', 3);
    setState(() => _overlayEnabled = true);
    _controller!.clear();
    _controller!.resume();
    _startAdmission(widget.player.state.position.inMilliseconds);
    await _measure('overlay-restored', 4);
    _admission?.cancel();
    await widget.player.pause();
    _controller!.pause();
    _controller!.clear();
    await _measure('cleared-with-cache', 3);
    _renderer!.rasters.clear();
    await _measure('cache-cleared', 5);
    final retired = _renderer!;
    setState(() => _case = -1);
    await WidgetsBinding.instance.endOfFrame;
    _results.add({
      'phase': 'renderer-disposed',
      'statistics': retired.statistics,
      'process': _processMetrics.sample(),
    });
    _controller = null;
    _renderer = null;
  }

  Future<void> _runEndurance() async {
    await _newCase(true);
    final overallWatch = Stopwatch()..start();
    final progressBefore = _mediaProgressMs;
    final wrapsBefore = _mediaWraps;
    final backwardsBefore = _unexpectedBackwards;
    final statisticsBefore = _renderer!.statistics;
    var remaining = _measurementSeconds;
    var checkpoint = 0;
    while (remaining > 0) {
      final seconds = remaining > 60 ? 60 : remaining;
      await _measure('endurance-$checkpoint', seconds);
      remaining -= seconds;
      checkpoint++;
      if (_results.last['expectedPlaying'] != true ||
          _results.last['replayWindowValid'] != true) {
        throw StateError('Invalid endurance playback window');
      }
    }
    overallWatch.stop();
    final progress = _mediaProgressMs - progressBefore;
    final backwards = _unexpectedBackwards - backwardsBefore;
    final valid =
        widget.player.state.playing &&
        backwards == 0 &&
        (progress - overallWatch.elapsedMilliseconds).abs() <= 1000;
    _results.add({
      'phase': 'endurance-overall',
      'durationSeconds': overallWatch.elapsedMicroseconds / 1000000,
      'mediaProgressMs': progress,
      'mediaWraps': _mediaWraps - wrapsBefore,
      'unexpectedBackwards': backwards,
      'expectedPlaying': widget.player.state.playing,
      'replayWindowValid': valid,
      'frames': 0,
      'frameTimingsRecorded': false,
      'telemetrySamples': <Object?>[],
      'statisticsBefore': statisticsBefore,
      'statistics': _renderer!.statistics,
      'processAtEnd': _processMetrics.sample(),
    });
    if (!valid) throw StateError('Invalid overall endurance playback');
    _admission?.cancel();
    _controller!.pause();
    _controller!.clear();
    await _measure('cleared-with-cache', 20);
    _renderer!.rasters.clear();
    await _measure('cache-cleared', 20);
    final retired = _renderer!;
    setState(() => _case = -1);
    await WidgetsBinding.instance.endOfFrame;
    _controller = null;
    _renderer = null;
    await _measure('renderer-disposed', 20);
    _results.last['retiredRenderer'] = retired.statistics;
    await widget.player.pause();
    await widget.player.dispose();
    _playerDisposed = true;
    stdout.writeln('PLAYBACK_BENCH_BEGIN media-disposed');
    await Future<void>.delayed(const Duration(seconds: 20));
    _results.add({
      'phase': 'media-disposed',
      'processAtEnd': _processMetrics.sample(),
    });
  }

  Future<void> _run() async {
    var code = 0;
    final mpvVersion = _property('mpv-version');
    final ffmpegVersion = _property('ffmpeg-version');
    try {
      await widget.video.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 15),
      );
      if (_config.kind == 'endurance') {
        await _runEndurance();
      } else if (_config.kind == 'lifecycle') {
        await _runLifecycle();
      } else {
        for (var repetition = 0; repetition < _repetitions; repetition++) {
          final modes = switch (_config.renderer) {
            'baseline' => [false],
            'prepared' => [true],
            _ => repetition.isEven ? [false, true] : [true, false],
          };
          for (final prepared in modes) {
            await _newCase(prepared);
            await _measure(
              'stress',
              _measurementSeconds,
              repetition: repetition,
            );
          }
        }
      }
      _admission?.cancel();
      final output = File(_outputPath);
      await output.parent.create(recursive: true);
      await output.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'schemaVersion': 1,
          'configuration': _config.toJson(),
          'devicePixelRatio': mounted
              ? MediaQuery.devicePixelRatioOf(context)
              : null,
          'fixture': widget.fixture,
          'mpvVersion': mpvVersion,
          'ffmpegVersion': ffmpegVersion,
          'results': _results,
        }),
      );
      stdout.writeln('PLAYBACK_BENCH_OUTPUT ${output.absolute.path}');
    } catch (error, stack) {
      stderr.writeln('$error\n$stack');
      code = 1;
    }
    _admission?.cancel();
    _telemetryTimer?.cancel();
    setState(() => _case = -1);
    await WidgetsBinding.instance.endOfFrame;
    if (!_playerDisposed) await widget.player.dispose();
    await Future<void>.delayed(const Duration(seconds: 6));
    stdout.writeln('PLAYBACK_BENCH_READY code=$code close the window manually');
    // READY 只表示测量和媒体释放完成，不表示 Windows 已成功退出。
    // 生命周期回归通过后由测试脚本关闭窗口；不在此调用 exit 或 exitApplication。
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
    if (!(_ready?.isCompleted ?? true)) _ready!.complete();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF205080),
    body: LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest * _viewportScale;
        _updateVideoOutputSize(size);
        return Align(
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: size,
            child: Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(child: SimpleVideo(controller: widget.video)),
                if (_case >= 0)
                  if (_prepared)
                    Opacity(
                      opacity: _config.composition == 'reference-group'
                          ? _config.opacity
                          : 1,
                      child: WindowsDanmakuScreen<void>(
                        key: ValueKey(_case),
                        option: _option,
                        size: size,
                        opacity: _overlayEnabled
                            ? (_config.composition == 'reference-group'
                                  ? 1
                                  : _config.opacity)
                            : 0,
                        rasterCacheMaxBytes: _config.cacheMiB * 1024 * 1024,
                        rasterCacheMaxEntries: _config.cacheEntries,
                        createdRenderer: (renderer) {
                          _renderer = renderer;
                          _created(renderer.controller);
                        },
                      ),
                    )
                  else
                    Opacity(
                      opacity: _config.opacity,
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
                    '$_phase / ${_prepared ? 'prepared' : 'baseline'} / ${_config.cacheMiB} MiB / $_case',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  void _updateVideoOutputSize(Size viewport) {
    if (!_fitVideoOutputToViewport ||
        viewport.width <= 0 ||
        viewport.height <= 0) {
      return;
    }
    final size = calculateVideoOutputSize(
      logicalWidth: viewport.width,
      logicalHeight: viewport.height,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      sourceWidth: widget.video.player.state.width,
      sourceHeight: widget.video.player.state.height,
    );
    if (size == null || size == _videoOutputSize) return;
    _videoOutputSize = size;
    _videoOutputRequests++;
    unawaited(widget.video.setSize(width: size.width, height: size.height));
  }

  @override
  void dispose() {
    _admission?.cancel();
    _telemetryTimer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }
}
