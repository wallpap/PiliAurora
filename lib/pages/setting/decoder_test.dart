import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/http/browser_ua.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/models/hwdec_type.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_playback_runtime.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_runtime_slot.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/plugin/pl_player/utils/native_video_options.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/process_metrics.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

typedef DecoderMediaHeaderWriter = void Function({
  String? userAgent,
  String? referer,
});

void configureDecoderTestMediaHeaders(DecoderMediaHeaderWriter write) =>
    write(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);

String decoderTestLabel(HwDecType decoder) => switch (decoder) {
  HwDecType.autoSafe => '自动选择（安全）',
  HwDecType.autoCopy => '自动选择（复制）',
  _ =>
    '${decoder.desc.split('：').first}${decoder.hwdec.endsWith('-copy') ? '（复制）' : ''}',
};

/// 同一编码优先使用请求的 1080p 档，避免把接口中的首个 4K/高帧率档拿来比较。
List<VideoItem> decoderTestSamples(Iterable<VideoItem> videos) {
  final result = <VideoItem>[];
  for (final codec in [7, 12, 13]) {
    final candidates =
        videos
            .where(
              (video) =>
                  video.codecid == codec &&
                  video.playUrls.any((url) => url.trim().isNotEmpty),
            )
            .toList()
          ..sort((a, b) {
            int rank(VideoItem item) => item.id == 80
                ? 0
                : item.id < 80
                ? 1
                : 2;
            final order = rank(a).compareTo(rank(b));
            return order != 0
                ? order
                : rank(a) == 2
                ? a.id.compareTo(b.id)
                : b.id.compareTo(a.id);
          });
    if (candidates.isNotEmpty) result.add(candidates.first);
  }
  return result;
}

class DecoderPerformance {
  const DecoderPerformance({
    this.averageCpu,
    this.peakMemoryMb,
    this.averageGpu,
  });
  final double? averageCpu, peakMemoryMb, averageGpu;
}

class DecoderTestResult {
  const DecoderTestResult.running()
    : running = true,
      cancelled = false,
      passed = false,
      fallback = false,
      decoder = null,
      size = null,
      speed = null,
      error = null,
      performance = null;
  const DecoderTestResult.cancelled()
    : running = false,
      cancelled = true,
      passed = false,
      fallback = false,
      decoder = null,
      size = null,
      speed = null,
      error = null,
      performance = null;
  const DecoderTestResult.failure(this.error, {this.performance})
    : running = false,
      cancelled = false,
      passed = false,
      fallback = false,
      decoder = null,
      size = null,
      speed = null;
  const DecoderTestResult.success({
    required this.decoder,
    required this.size,
    required this.speed,
    required this.fallback,
    required this.performance,
  }) : running = false,
       cancelled = false,
       passed = true,
       error = null;
  final bool running, cancelled, passed, fallback;
  final String? decoder, size, error;
  final double? speed;
  final DecoderPerformance? performance;
}

class DecoderTestObservation {
  const DecoderTestObservation({
    required this.decoder,
    required this.format,
    required this.position,
    required this.consumedFrames,
    required this.videoProgressing,
    required this.width,
    required this.height,
    this.buffering = false,
  });
  final String decoder, format;
  final Duration position;
  final int consumedFrames, width, height;
  final bool videoProgressing, buffering;
}

DecoderTestResult evaluateDecoderTest({
  required HwDecType requested,
  required int codec,
  required DecoderTestObservation before,
  required DecoderTestObservation after,
  required Duration elapsed,
  DecoderPerformance performance = const DecoderPerformance(),
}) {
  if (after.decoder.trim().isEmpty) throw StateError('未能确认实际解码器');
  if (after.format != {7: 'h264', 12: 'hevc', 13: 'av1'}[codec]) {
    throw StateError('实际视频编码与测试样本不符');
  }
  if (after.width <= 0 ||
      after.height <= 0 ||
      !after.videoProgressing ||
      after.consumedFrames <= before.consumedFrames) {
    throw StateError('未确认持续输出画面');
  }
  final played = after.position - before.position;
  if (after.buffering ||
      elapsed <= Duration.zero ||
      played.inMicroseconds < elapsed.inMicroseconds * 2 / 3) {
    throw StateError('视频未能持续播放，请检查网络或输出状态');
  }
  final actual = after.decoder.trim();
  final automatic = [
    HwDecType.auto,
    HwDecType.autoSafe,
    HwDecType.autoCopy,
  ].contains(requested);
  final fallback = automatic
      ? actual == 'no' ||
            (requested == HwDecType.autoCopy && !actual.endsWith('-copy'))
      : actual != requested.hwdec;
  final mode = HwDecType.values
      .where((item) => item.hwdec == actual)
      .firstOrNull;
  return DecoderTestResult.success(
    decoder: mode == null ? actual : decoderTestLabel(mode),
    size: '${after.width}x${after.height}',
    speed: played.inMicroseconds / elapsed.inMicroseconds,
    fallback: fallback,
    performance: performance,
  );
}

typedef DecoderTestSessionFactory = DecoderTestSession Function(
  HwDecType decoder,
  VideoItem sample,
);

abstract interface class DecoderTestSession {
  ValueListenable<VideoController?> get videoController;
  Future<DecoderTestResult> run();
  Future<void> dispose();
}

/// 每个组合使用独立播放会话；超时或停止后先确认原生释放，再允许下一个组合。
class NativeDecoderTestSession implements DecoderTestSession {
  NativeDecoderTestSession(this.decoder, this.sample) {
    _runtime = NativePlaybackRuntime(
      configuration: PlaybackRuntimeConfig(
        playerOptions: {
          'audio': 'no',
          'video-sync': Pref.videoSync,
          ...nativeVideoPlayerOptions(),
        },
        // 软件基线只切换 hwdec，保持相同的视频输出路径。
        hardwareAccelerationEnabled: true,
        hardwareDecoder: decoder.hwdec,
        width: sample.width,
        height: sample.height,
        enableAndroidTextureScaling: Pref.enableAndroidTextureScaling,
        readAndroidTextureScaling: () => Pref.enableAndroidTextureScaling,
      ),
      diagnosticsExtra: () => {
        'purpose': 'decoderTest',
        'requestedDecoder': decoder.hwdec,
      },
      resourceSlot: _resources,
    );
    _session = PlaybackSession(runtime: _runtime, loadBudget: _startupTimeout);
    _owner = _session.attach();
  }

  static final _resources = PlaybackRuntimeSlot.isolated();
  static const _startupTimeout = Duration(seconds: 10);
  static const _measureLength = Duration(seconds: 3);
  final HwDecType decoder;
  final VideoItem sample;
  late final NativePlaybackRuntime _runtime;
  late final PlaybackSession _session;
  late final PlaybackOwner _owner;
  final _cancelled = Completer<void>();
  final _monitor = _PerformanceMonitor();
  Future<void>? _disposeFuture;

  @override
  ValueListenable<VideoController?> get videoController =>
      _runtime.videoControllerListenable;

  void _checkOpen() {
    if (_cancelled.isCompleted) throw const _TestCancelled();
  }

  Future<void> _delay(Duration duration) {
    _checkOpen();
    final done = Completer<void>();
    final timer = Timer(duration, done.complete);
    unawaited(
      _cancelled.future.then((_) {
        timer.cancel();
        if (!done.isCompleted) done.completeError(const _TestCancelled());
      }),
    );
    return done.future;
  }

  DecoderTestObservation _observe() {
    _checkOpen();
    final player = _runtime.player;
    if (player == null) throw StateError('测试播放器尚未就绪');
    final actual = _session.currentSnapshot.actual;
    return DecoderTestObservation(
      decoder: player.getProperty('hwdec-current'),
      format: player.getProperty('video-format'),
      // 会话快照只在状态变化时发布；持续播放的位置从运行时读取。
      position: _runtime.position ?? Duration.zero,
      consumedFrames:
          (_runtime.videoFrameDiagnostics['consumedFrameSamples'] as int?) ?? 0,
      videoProgressing: actual.videoProgressing == true,
      width: player.state.width,
      height: player.state.height,
      buffering: actual.buffering == true,
    );
  }

  @override
  Future<DecoderTestResult> run() async {
    final clock = Stopwatch()..start();
    try {
      _checkOpen();
      final headers = <String, String>{};
      configureDecoderTestMediaHeaders(({String? userAgent, String? referer}) {
        if (userAgent != null) headers['User-Agent'] = userAgent;
        if (referer != null) headers['Referer'] = referer;
      });
      final url = sample.playUrls
          .firstWhere((url) => url.trim().isNotEmpty)
          .trim();
      final loaded = await _owner.load(
        PlaybackPlan(
          contentKey: 'decoder-test:${sample.codecid}:${decoder.hwdec}',
          source: PlaybackSourceSnapshot.fromDataSource(
            NetworkSource(videoSource: url, audioSource: null),
            headers: headers,
          ),
          timeline: const PlaybackTimeline(
            kind: PlaybackTimelineKind.onDemand,
            seekPolicy: PlaybackSeekPolicy.allowed,
          ),
          configuration: PlaybackConfiguration(
            hwdec: decoder.hwdec,
          ),
        ),
        start: PlaybackStartPolicy.play,
      );
      _checkOpen();
      if (loaded.outcome != LoadOutcome.ready) {
        throw StateError(loaded.failure?.cause ?? '测试视频加载未完成');
      }
      var before = _observe();
      while (!before.videoProgressing ||
          before.position < const Duration(seconds: 1)) {
        if (clock.elapsed >= _startupTimeout) {
          throw TimeoutException('尚未确认本视频持续输出画面');
        }
        await _delay(const Duration(milliseconds: 100));
        before = _observe();
      }
      _monitor.start();
      final began = clock.elapsed;
      while (clock.elapsed - began < _measureLength) {
        await _delay(const Duration(milliseconds: 250));
        if (_session.currentSnapshot.phase != PlaybackPhase.ready) {
          throw StateError('测试期间播放中断');
        }
      }
      return evaluateDecoderTest(
        requested: decoder,
        codec: sample.codecid!,
        before: before,
        after: _observe(),
        elapsed: clock.elapsed - began,
        performance: _monitor.stop(),
      );
    } on _TestCancelled {
      return const DecoderTestResult.cancelled();
    } catch (error) {
      Diagnostics.instance.playerLog(
        DiagnosticLogLevel.error,
        'decoderTest',
        error,
        details: {'decoder': decoder.hwdec, 'codec': sample.codecid},
      );
      return DecoderTestResult.failure(
        formatDecoderTestError(error),
        performance: _monitor.stop(),
      );
    } finally {
      _monitor.stop();
    }
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _cancelled.complete();
    _monitor.stop();
    _owner.close();
    final result = await _session.shutdown();
    if (result.outcome != PlaybackShutdownOutcome.released) {
      throw StateError('测试资源尚未确认释放');
    }
    await _runtime.released;
  }
}

String formatDecoderTestError(Object error) {
  final message = error.toString().replaceFirst('Bad state: ', '');
  return message.length > 100 ? '初始化或播放失败，请查看诊断日志' : message;
}

class _TestCancelled implements Exception {
  const _TestCancelled();
}

class _PerformanceMonitor {
  Timer? _timer;
  final _metrics = ProcessMetrics();
  double _cpuTotal = 0;
  int _cpuSamples = 0;
  double? _peakMemoryMb;
  bool _started = false;

  void start() {
    _metrics.reset();
    _started = true;
    _record();
    _timer = Timer.periodic(
      const Duration(milliseconds: 750),
      (_) => _record(),
    );
  }

  DecoderPerformance stop() {
    _timer?.cancel();
    _timer = null;
    if (_started) _record();
    _started = false;
    return DecoderPerformance(
      averageCpu: _cpuSamples == 0 ? null : _cpuTotal / _cpuSamples,
      peakMemoryMb: _peakMemoryMb,
    );
  }

  void _record() {
    final values = _metrics.sample();
    if (values['cpuPercentMachine'] case final num cpu) {
      _cpuTotal += cpu;
      _cpuSamples++;
    }
    if (values['rssBytes'] case final num bytes) {
      _peakMemoryMb = math.max(_peakMemoryMb ?? 0, bytes / 1048576);
    }
  }
}
