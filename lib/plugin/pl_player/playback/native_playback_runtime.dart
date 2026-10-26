import 'dart:async';
import 'dart:io';
import 'dart:developer' show Timeline;

import 'package:pili_aurora/plugin/pl_player/playback/frame_timing.dart';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/http/browser_ua.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_media_clock_sampling.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_media_clock_worker.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_load_readiness.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_runtime_slot.dart';
import 'package:pili_aurora/plugin/pl_player/playback/shader_updates.dart';
import 'package:pili_aurora/plugin/pl_player/playback/video_frame_timings.dart';
import 'package:pili_aurora/plugin/pl_player/utils/android_raster_scheduling.dart';
import 'package:pili_aurora/plugin/pl_player/utils/hardware_video_configuration.dart';
import 'package:pili_aurora/plugin/pl_player/utils/native_audio_recovery.dart';
import 'package:pili_aurora/plugin/pl_player/utils/native_media_source.dart';
import 'package:pili_aurora/services/android_video_output_limit.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/player_diagnostics.dart';
import 'package:pili_aurora/services/windows_video_output_limit.dart';

/// 一个控制器生命周期内的原生资源 owner。
///
/// Session 将所有业务命令送入此对象；这里串行化真正触碰 Player 的操作，
/// 并以原生 entry ID、hook 和输出令牌建立每份媒体的生命周期边界。
class NativePlaybackRuntime
    implements
        PlaybackRuntimePort,
        PlaybackSeekSubmissionGate,
        PlaybackMediaClockSampler {
  NativePlaybackRuntime({
    required this.configuration,
    required this.diagnosticsExtra,
  });

  static int _nextRuntimeId = 1;
  static final Stopwatch _fallbackClock = Stopwatch()..start();
  static Duration _fallbackNow() => _fallbackClock.elapsed;

  @override
  final int runtimeId = _nextRuntimeId++;

  @override
  Duration? get position => _player?.state.position;

  final PlaybackRuntimeConfig configuration;
  final Map<String, Object?> Function() diagnosticsExtra;

  @override
  bool get shaderChangeRequiresRendererReset =>
      Platform.isWindows &&
      _player != null &&
      _videoController != null &&
      _activeBinding != null &&
      _player!.state.width > 0;

  final _frameTimings = PlaybackVideoFrameTimings(
    useRequestTimings: Platform.isAndroid,
  );
  PlaybackFrameSource get frameSource => _frameTimings;
  ValueListenable<bool> get videoFramePresented => _frameTimings.presented;
  final ValueNotifier<bool> videoDisplaySyncActive = ValueNotifier(false);
  final StreamController<PlaybackRuntimeEvent> _events =
      StreamController<PlaybackRuntimeEvent>.broadcast(sync: true);
  final Completer<void> _released = Completer<void>();
  final Map<int, _NativeFileBinding> _bindings = {};
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Map<String, double> _lastPts = {};

  Player? _player;
  VideoController? _videoController;
  AndroidRasterScheduling? _rasterScheduling;
  final _videoControllerListenable = ValueNotifier<VideoController?>(null);
  PlayerDiagnostics? _diagnostics;
  NativeHookRegistration? _hookRegistration;
  Future<void>? _initializeFuture;
  Future<void> _operationTail = Future<void>.value();
  Future<PlaybackShutdownResult>? _shutdownFuture;
  _PendingNativeLoad? _pendingLoad;
  _NativeFileBinding? _activeBinding;
  PlaybackPlan? _activePlan;
  Duration Function() _activeNow = _fallbackNow;
  Duration? _lastAudioPtsAdvance;
  Duration? _lastVideoFrameAdvance;
  Duration? _lastVideoFrameConsumed;
  double? _lastVideoFrameNumber;
  double? _selectedVideoFps;
  bool? _selectedVideoTrack;
  PlaybackActual? _lastPublishedActual;
  PlaybackCapabilities? _lastPublishedCapabilities;
  Timer? _healthExpiry;
  Duration? _healthExpiryDeadline;
  int _outputEpoch = 0;
  int _configRevision = 0;
  String _appliedShaderList = '';
  int _lastBatchId = 0;
  bool _shutdownRequested = false;
  bool _nativeLifecycleUnknown = false;
  bool _nativeOpenNeedsRetirement = false;
  bool _seeking = false;
  int _mediaClockSeekSequence = 0;
  int _mediaClockContinuity = 0;
  bool _mediaClockSeekPending = false;
  final _mediaClockSampling = NativeMediaClockSampling();
  bool _seekSubmissionBlocked = false;
  final _seekSubmissionChanges = StreamController<void>.broadcast(sync: true);
  Timer? _seekObservationTimeout;

  @override
  bool get seekSubmissionBlocked => _seekSubmissionBlocked;
  @override
  Stream<void> get seekSubmissionChanges => _seekSubmissionChanges.stream;

  void _releaseSeekObservation() {
    _seekObservationTimeout?.cancel();
    _seekObservationTimeout = null;
    if (!_seekSubmissionBlocked) return;
    _seekSubmissionBlocked = false;
    _seekSubmissionChanges.add(null);
  }

  bool _buffering = false;
  bool _playing = false;
  bool? _hasVideo;
  bool? _hasAudio;
  bool? _seekable;
  bool? _partiallySeekable;

  @override
  Stream<PlaybackRuntimeEvent> get events => _events.stream;

  @override
  Future<void> get released => _released.future;

  Player? get player => _player;
  VideoController? get videoController => _videoController;
  ValueListenable<VideoController?> get videoControllerListenable =>
      _videoControllerListenable;
  PlayerDiagnostics? get diagnostics => _diagnostics;

  Map<String, Object?> get videoFrameDiagnostics =>
      _frameTimings.diagnostics(Timeline.now);

  @override
  Future<PlaybackRuntimeLoadResult> load(
    PlaybackPlan plan,
    PlaybackExecutionContext context,
  ) => _serialize(() => _load(plan, context));

  @override
  Future<PlaybackRuntimeCommandResult> setPlaying(
    bool playing,
    PlaybackExecutionContext context,
  ) => _serialize(() async {
    final player = _usablePlayer(context);
    if (player == null) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    if (playing) {
      await player.play();
    } else {
      await player.pause();
    }
    if (!context.isCurrent()) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    return const PlaybackRuntimeCommandResult();
  });

  @override
  Future<PlaybackRuntimeCommandResult> seek(
    Duration target,
    PlaybackExecutionContext context,
  ) => _serialize(() async {
    final player = _usablePlayer(context);
    if (player == null) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    if (_mediaClockSeekPending) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    _mediaClockSeekSequence = context.seekSequence;
    _mediaClockSeekPending = true;
    _samplingSeekConfirmed = false;
    _syncVideoFrameSampling();
    _seekSubmissionBlocked = true;
    _seekObservationTimeout = Timer(const Duration(seconds: 5), () {
      _seekObservationTimeout = null;
      _diagnostics?.event(
        'media.seek.observation.timeout',
        details: {
          'loadId': context.loadId,
          'seekSequence': context.seekSequence,
        },
      );
    });
    try {
      await player.seek(target, observationId: context.seekSequence);
    } catch (_) {
      _mediaClockSeekPending = false;
      _releaseSeekObservation();
      sampleMediaClock();
      rethrow;
    }
    if (!context.isCurrent()) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    return const PlaybackRuntimeCommandResult();
  });

  @override
  Future<PlaybackRuntimeCommandResult> setPlaybackSpeed(
    double value,
    Map<String, String> mediaOptions,
    PlaybackExecutionContext context,
  ) => _serialize(() async {
    final player = _usablePlayer(context);
    if (player == null) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    await player.setRate(value);
    sampleMediaClock();
    if (!context.isCurrent()) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    try {
      for (final name in const ['cache-secs', 'demuxer-hysteresis-secs']) {
        final option = mediaOptions[name];
        if (option != null) player.setProperty(name, option);
      }
    } catch (error) {
      return PlaybackRuntimeCommandResult(
        applied: false,
        failure: _failure(
          PlaybackFailureCategory.capability,
          'update-buffer-for-speed',
          error,
        ),
      );
    }
    _configRevision++;
    return const PlaybackRuntimeCommandResult();
  });

  @override
  Future<PlaybackRuntimeCommandResult> setVolume(
    double value,
    PlaybackExecutionContext context,
  ) => _serialize(() async {
    final player = _usablePlayer(context);
    if (player == null) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    await player.setVolume(value);
    if (!context.isCurrent()) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    _configRevision++;
    return const PlaybackRuntimeCommandResult();
  });

  @override
  Future<PlaybackRuntimeCommandResult> setAudioOnly(
    bool value,
    PlaybackExecutionContext context,
  ) => _serialize(() async {
    final player = _usablePlayer(context);
    if (player == null) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    final videoTrackId = _activePlan?.configuration.videoTrackId;
    final track = value
        ? VideoTrack.no()
        : videoTrackId == null
        ? VideoTrack.auto()
        : VideoTrack('$videoTrackId', null, null);
    await player.setVideoTrack(track);
    if (!context.isCurrent()) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    if (value) {
      _hasVideo = false;
      _selectedVideoTrack = false;
      _selectedVideoFps = null;
    } else {
      _hasVideo = null;
      _selectedVideoTrack = null;
      _selectedVideoFps = null;
    }
    _emitCapabilities(context.loadId);
    _configRevision++;
    return const PlaybackRuntimeCommandResult();
  });

  @override
  Future<PlaybackRuntimeCommandResult> setAudioTrack(
    int? trackId,
    PlaybackExecutionContext context,
  ) => _serialize(() async {
    final player = _usablePlayer(context);
    if (player == null) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    await player.setAudioTrack(
      trackId == null ? AudioTrack.auto() : AudioTrack('$trackId', null, null),
    );
    if (!context.isCurrent()) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    _hasAudio = null;
    _lastAudioPtsAdvance = null;
    _emitCapabilities(context.loadId);
    _configRevision++;
    return const PlaybackRuntimeCommandResult();
  });

  @override
  Future<PlaybackRuntimeCommandResult> reloadAudio(
    PlaybackExecutionContext context,
  ) => _serialize(() async {
    final player = _usablePlayer(context);
    final audio = _activePlan?.source.currentAudioSource;
    if (player == null || audio == null) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    final applied = await reloadNativeAudio(
      player: player,
      audioUrl: audio,
      trackList: _diagnostics?.property('track-list'),
      isCurrent: context.isCurrent,
    );
    if (applied) {
      _lastPts.remove('audio');
      _lastAudioPtsAdvance = null;
      _emitActual(context.loadId);
    }
    return PlaybackRuntimeCommandResult(applied: applied);
  });

  @override
  Future<PlaybackRuntimeCommandResult> setSubtitleTrack(
    PlaybackSubtitleTrack? track,
    PlaybackExecutionContext context,
  ) => _serialize(() async {
    final player = _usablePlayer(context);
    if (player == null) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    await player.setSubtitleTrack(_nativeSubtitleTrack(track));
    if (!context.isCurrent()) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    _configRevision++;
    return const PlaybackRuntimeCommandResult();
  });

  @override
  Future<PlaybackRuntimeCommandResult> setDecoder(
    PlaybackDecoder decoder,
    PlaybackExecutionContext context,
  ) => _serialize(() async {
    final player = _usablePlayer(context);
    if (player == null) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    player.setProperty('hwdec', decoder.value);
    if (!context.isCurrent()) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    _configRevision++;
    return const PlaybackRuntimeCommandResult();
  });

  @override
  Future<PlaybackRuntimeCommandResult> setShader(
    List<String> shaders,
    PlaybackExecutionContext context,
  ) => _serialize(() async {
    final player = _usablePlayer(context);
    if (player == null) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    final output = _videoController;
    final reset = shaderChangeRequiresRendererReset;
    final shaderList = shaders.join(Platform.isWindows ? ';' : ':');
    await applyShaderList(
      shaderList,
      command: player.command,
      resetRenderer: reset ? output!.resetRenderer : null,
    );
    _appliedShaderList = shaderList;
    if (!context.isCurrent()) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    _configRevision++;
    return const PlaybackRuntimeCommandResult();
  });

  @override
  Future<PlaybackShutdownResult> shutdown() {
    _shutdownRequested = true;
    _syncVideoFrameSampling();
    _releaseSeekObservation();
    if (_shutdownFuture == null && _player != null) {
      Diagnostics.instance.playerLog(
        DiagnosticLogLevel.info,
        'player',
        'runtime.shutdown.requested',
        details: {'runtimeId': runtimeId, 'loadId': _activeBinding?.loadId},
      );
    }
    return _shutdownFuture ??= _serialize(_shutdown);
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = Completer<T>();
    final run = _operationTail.then<void>((_) async {
      try {
        result.complete(await action());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    _operationTail = run.catchError((Object _) {});
    return result.future;
  }

  Future<PlaybackRuntimeLoadResult> _load(
    PlaybackPlan plan,
    PlaybackExecutionContext context,
  ) async {
    if (_shutdownRequested || !context.isCurrent()) {
      return _loadFailure(
        PlaybackFailureCategory.timeout,
        'load',
        StateError('Load request is no longer current.'),
      );
    }
    if (_nativeLifecycleUnknown) {
      return _loadFailure(
        PlaybackFailureCategory.capability,
        'native-lifecycle',
        StateError('Native file identity or unload barrier is unknown.'),
      );
    }

    final player = await _ensureInitialized(context);
    if (player == null) {
      return _loadFailure(
        PlaybackFailureCategory.timeout,
        'initialize',
        TimeoutException('The runtime slot or initialization budget expired.'),
      );
    }
    if (!context.isCurrent() || _shutdownRequested) {
      return _loadFailure(
        PlaybackFailureCategory.timeout,
        'initialize',
        StateError('Load expired during native player initialization.'),
      );
    }

    _PendingNativeLoad? pendingLoad;
    try {
      await _unloadActiveFile(player, context);
      if (!context.isCurrent()) return _supersededLoad();
      _activePlan = null;
      _lastPublishedCapabilities = null;

      final output = _videoController;
      if (output == null) {
        return _loadFailure(
          PlaybackFailureCategory.output,
          'create-video-output',
          StateError('Video output controller is unavailable.'),
        );
      }

      final token = OutputOperationToken(
        runtimeId: runtimeId,
        loadId: context.loadId,
        outputEpoch: ++_outputEpoch,
        configRevision: _configRevision,
      );
      _samplingEnabled = false;
      _samplingSeekConfirmed = true;
      _frameTimings.beginLoad(token, Timeline.now);
      await output.beginOutputForLoad(token);
      if (!context.isCurrent()) {
        await output.invalidateOutputGeneration(token);
        return _supersededLoad();
      }

      final pending = _PendingNativeLoad(
        plan: plan,
        context: context,
        token: token,
      );
      pendingLoad = pending;
      _pendingLoad = pending;
      context.registerCancellation(() {
        pending.binding?.retiring = true;
        if (!pending.result.isCompleted) {
          pending.result.complete(_supersededLoad());
        }
      });
      _activeNow = context.monotonicNow;
      _resetHealthEvidence();

      player
        ..setMediaHeader(
          userAgent: BrowserUa.pc,
          referer: HttpString.baseUrl,
          headers: plan.source.headers.isEmpty ? null : plan.source.headers,
        )
        ..setProperty('hwdec', plan.configuration.hwdec);
      await player.setRate(plan.configuration.playbackSpeed);
      if (!context.isCurrent()) {
        await output.invalidateOutputGeneration(token);
        return _supersededLoad();
      }
      await player.setVolume(plan.configuration.volume);
      if (!context.isCurrent()) {
        await output.invalidateOutputGeneration(token);
        return _supersededLoad();
      }

      final source = nativeMediaSourceFromSnapshot(
        source: plan.source,
        audioOnly: plan.configuration.audioOnly,
        start: plan.timeline.kind == PlaybackTimelineKind.live
            ? null
            : (plan.reloadPosition ?? plan.startPosition),
        extras: plan.configuration.mediaOptions,
      );
      // Shader lists are player-wide state. Prepare them after the previous
      // file has crossed its unload barrier and before opening this media so a
      // Windows renderer reset cannot reinitialize an active (possibly live)
      // stream. Always send the list, including an empty one, to clear a prior
      // media's filters.
      final shaderList = plan.configuration.shaders.join(
        Platform.isWindows ? ';' : ':',
      );
      await applyShaderList(
        shaderList,
        command: player.command,
        resetRenderer: Platform.isWindows && shaderList != _appliedShaderList
            ? output.resetRenderer
            : null,
      );
      _appliedShaderList = shaderList;
      if (!context.isCurrent()) {
        await output.invalidateOutputGeneration(token);
        return _supersededLoad();
      }
      _diagnostics?.event(
        'media.open.requested',
        details: {
          'requestId': context.requestId,
          'loadId': context.loadId,
          'startMs': source.start?.inMilliseconds,
          'sourceType': plan.source.isNetwork ? 'network-snapshot' : 'local',
          'audioOnly': plan.configuration.audioOnly,
          'outputEpoch': token.outputEpoch,
        },
      );
      final watch = Stopwatch()..start();
      _nativeOpenNeedsRetirement = true;
      await player.open(source, play: false);
      // open 回执可能先于 start-file；取消后仍需保留归属，直到原生身份已知。
      await pending.started.future.timeout(_remaining(context));
      _diagnostics?.event(
        'media.open.completed',
        details: {
          'durationUs': watch.elapsedMicroseconds,
          'isCurrent': context.isCurrent(),
        },
      );
      if (!context.isCurrent()) {
        await output.invalidateOutputGeneration(token);
        return _supersededLoad();
      }

      final result = await _awaitPendingLoad(pending);
      if (!context.isCurrent()) {
        await output.invalidateOutputGeneration(token);
        return _supersededLoad();
      }
      if (result.loaded &&
          result.output.strategy != PlaybackOutputStrategy.unknown) {
        _mediaClockSeekSequence = context.seekSequence;
        _mediaClockContinuity++;
        _mediaClockSeekPending = false;
        _releaseSeekObservation();
        _activePlan = plan;
        final binding = pending.binding;
        if (binding != null) _activeBinding = binding;
        await _applyLoadedTrackConfiguration(player, plan, context);
        if (!context.isCurrent()) return _supersededLoad();
        _emitCapabilities(context.loadId);
        _emitActual(context.loadId);
        return PlaybackRuntimeLoadResult(
          loaded: true,
          output: result.output,
          failure: result.failure,
          capabilities: _currentCapabilities(),
        );
      }
      return result;
    } catch (error) {
      final category = error is TimeoutException
          ? PlaybackFailureCategory.timeout
          : PlaybackFailureCategory.source;
      final failure = _failure(category, 'load', error);
      final pending = pendingLoad;
      if (pending != null && !pending.result.isCompleted) {
        pending.result.complete(
          PlaybackRuntimeLoadResult(
            loaded: false,
            output: PlaybackOutputPreparation(
              strategy: PlaybackOutputStrategy.unknown,
              evidence: 'load-failed',
              outputEpoch: pending.token.outputEpoch,
              hasVideo: pending.hasVideo,
            ),
            failure: failure,
          ),
        );
      }
      _diagnostics?.event(
        'media.open.failed',
        level: DiagnosticLogLevel.error,
        details: {'loadId': context.loadId, 'error': error.toString()},
      );
      return PlaybackRuntimeLoadResult(
        loaded: false,
        output: PlaybackOutputPreparation(
          strategy: PlaybackOutputStrategy.unknown,
          evidence: 'load-failed',
          outputEpoch: pending?.token.outputEpoch ?? 0,
          hasVideo: pending?.hasVideo,
        ),
        failure: failure,
      );
    } finally {
      if (identical(_pendingLoad, pendingLoad)) _pendingLoad = null;
    }
  }

  Future<PlaybackRuntimeLoadResult> _awaitPendingLoad(
    _PendingNativeLoad pending,
  ) async {
    final remaining = pending.context.deadline - pending.context.monotonicNow();
    if (remaining <= Duration.zero) {
      return _loadFailure(
        PlaybackFailureCategory.timeout,
        'load',
        TimeoutException('Load deadline expired before native readiness.'),
      );
    }
    try {
      return await pending.result.future.timeout(remaining);
    } on TimeoutException catch (error) {
      await _videoController?.invalidateOutputGeneration(pending.token);
      return _loadFailure(PlaybackFailureCategory.timeout, 'load', error);
    } on _NativeIdentityFailure catch (error) {
      return _loadFailure(
        PlaybackFailureCategory.capability,
        'native-file-identity',
        error,
      );
    }
  }

  Future<void> _unloadActiveFile(
    Player player,
    PlaybackExecutionContext context,
  ) async {
    final binding = _activeBinding;
    if (binding == null) {
      // current 在 stop 后仍保留 Dart 来源列表。原生是否待卸载由已发出的
      // open 和匹配的 unload/end-file 回执决定，取消在下次 open 前可直接续载。
      if (_nativeOpenNeedsRetirement) {
        _markNativeLifecycleUnknown(
          'An issued native open has no confirmed file binding.',
        );
        throw StateError(
          'Native open has no confirmed native file identity.',
        );
      }
      return;
    }
    if (binding.unloaded && binding.endFileSeen) {
      _nativeOpenNeedsRetirement = false;
      _activeBinding = null;
      return;
    }
    if (binding.entryId == null || binding.token == null) {
      _nativeLifecycleUnknown = true;
      throw StateError(
        'Cannot retire a native file without identity and token.',
      );
    }
    binding.retiring = true;
    await player.stop();
    final remaining = context.deadline - context.monotonicNow();
    if (remaining <= Duration.zero) {
      throw TimeoutException('Load deadline expired while retiring old file.');
    }
    await binding.retired.future.timeout(remaining);
    await _videoController!.invalidateOutputGeneration(binding.token!);
    _bindings.remove(binding.entryId);
    _nativeOpenNeedsRetirement = false;
    _activeBinding = null;
  }

  Future<void> _applyLoadedTrackConfiguration(
    Player player,
    PlaybackPlan plan,
    PlaybackExecutionContext context,
  ) async {
    final trackId = plan.configuration.audioTrackId;
    await player.setAudioTrack(
      trackId == null ? AudioTrack.auto() : AudioTrack('$trackId', null, null),
    );
    if (!context.isCurrent()) return;
    await player.setSubtitleTrack(
      _nativeSubtitleTrack(plan.configuration.subtitleTrack),
    );
    if (!context.isCurrent()) return;
  }

  Future<Player?> _ensureInitialized(PlaybackExecutionContext context) {
    if (_player != null) return Future.value(_player);
    if (_shutdownRequested) return Future.value(null);
    final existing = _initializeFuture;
    if (existing != null) return existing.then((_) => _player);
    final future = _initialize(context);
    _initializeFuture = future;
    return future.whenComplete(() {
      if (identical(_initializeFuture, future)) _initializeFuture = null;
    });
  }

  Future<Player?> _initialize(PlaybackExecutionContext context) async {
    PlaybackRuntimeSlotLease? lease;
    Player? player;
    final watch = Stopwatch()..start();
    var previousStageUs = 0;
    void recordStage(String stage) {
      final elapsed = watch.elapsedMicroseconds;
      Diagnostics.instance.playerLog(
        DiagnosticLogLevel.info,
        'player',
        'runtime.initialize.$stage',
        details: {
          'runtimeId': runtimeId,
          'requestId': context.requestId,
          'loadId': context.loadId,
          'durationUs': elapsed,
          'stageDurationUs': elapsed - previousStageUs,
        },
      );
      previousStageUs = elapsed;
    }

    recordStage('begin');
    try {
      lease = await PlaybackRuntimeSlot.shared.acquire(
        deadline: context.deadline,
        now: context.monotonicNow,
        cancelled: context.cancelled,
        isCancelled: () => !context.isCurrent() || _shutdownRequested,
      );
      if (lease == null || !context.isCurrent() || _shutdownRequested) {
        lease?.release();
        return null;
      }
      recordStage('slot-acquired');
      try {
        player = await Player.create(
          configuration: PlayerConfiguration(
            logLevel: kDebugMode ? .warn : .error,
            options: configuration.playerOptions,
          ),
        );
      } on NativePlayerCreationFailure catch (error) {
        // Creation can fail after native allocation. Keep the process slot
        // isolated until this particular handle proves its destruction.
        lease.attachReleased(error.released);
        rethrow;
      }
      lease.attachReleased(player.released);
      _player = player;
      recordStage('player-created');
      if (!context.isCurrent() ||
          context.deadline <= context.monotonicNow() ||
          _shutdownRequested) {
        await _cleanupFailedInitialization(player);
        return null;
      }
      _subscriptions.add(
        player.nativeEvents.listen(
          _handleNativeEvent,
          onError: (Object error, StackTrace stack) =>
              _handleRuntimeNativeError(error),
        ),
      );
      _hookRegistration = player.registerLifecycleHookHandler(
        _handleLifecycleHook,
      );
      _diagnostics = PlayerDiagnostics(player, extra: diagnosticsExtra);

      final base = hardwareVideoConfiguration(
        enabled: configuration.hardwareAccelerationEnabled,
        configured: configuration.hardwareDecoder,
        windowsSourceSize:
            Platform.isWindows &&
                configuration.width != null &&
                configuration.height != null
            ? (width: configuration.width!, height: configuration.height!)
            : null,
        windowsOutputLimit: Platform.isWindows
            ? WindowsVideoOutputLimit.detected
            : null,
        androidOutputLimit: Platform.isAndroid
            ? () => configuration.enableAndroidTextureScaling
                  ? AndroidVideoOutputLimit.detected
                  : null
            : null,
        onAndroidDiagnostic: (event, details) => _diagnostics?.event(
          event,
          level: event.contains('error')
              ? DiagnosticLogLevel.error
              : DiagnosticLogLevel.info,
          details: details,
        ),
      );
      // The explicit preloaded participant owns paused-load surface sizing;
      // the legacy post-videoParams attach mode bypasses that proof gate.
      final videoConfiguration = VideoControllerConfiguration(
        vo: base.vo,
        hwdec: base.hwdec,
        width: base.width,
        height: base.height,
        enableHardwareAcceleration: base.enableHardwareAcceleration,
        androidOutputLimitWidth: base.androidOutputLimitWidth,
        androidOutputLimitHeight: base.androidOutputLimitHeight,
        androidOutputLimit: base.androidOutputLimit,
        onAndroidDiagnostic: base.onAndroidDiagnostic,
        androidAttachSurfaceAfterVideoParameters: false,
      );
      final video = await VideoController.create(
        player,
        configuration: videoConfiguration,
      );
      _videoController = video;
      if (Platform.isAndroid) {
        try {
          _rasterScheduling = await AndroidRasterScheduling.open();
          _rasterScheduling?.useAppCpus(true);
          if (_rasterScheduling case final scheduling?) {
            _diagnostics?.event(
              'raster.scheduling.applied',
              details: scheduling.diagnostics,
            );
          }
        } catch (_) {
          _diagnostics?.event('raster.scheduling.unavailable');
        }
      }
      if (!context.isCurrent() ||
          context.deadline <= context.monotonicNow() ||
          _shutdownRequested) {
        await _cleanupFailedInitialization(player);
        return null;
      }
      if (Platform.isAndroid) player.setProperty('force-window', 'no');
      player.setMediaHeader(
        userAgent: BrowserUa.pc,
        referer: HttpString.baseUrl,
      );
      _subscribePlayerState(player);
      _subscriptions.add(
        player
            .observeProperty('display-sync-active')
            .listen(
              (value) => _setDisplaySyncActive(value == 'yes'),
              onError: (Object _) => _setDisplaySyncActive(false),
            ),
      );
      _subscriptions.add(
        player
            .observeProperty('audio-pts')
            .listen(
              (value) => _observePts('audio', value),
              onError: (Object _) => _observePts('audio', null),
            ),
      );
      _subscriptions.add(
        player
            .observeProperty('estimated-frame-number')
            .listen(
              _observeVideoFrameNumber,
              onError: (Object _) => _observeVideoFrameNumber(null),
            ),
      );
      _subscriptions.add(
        player
            .observeProperty('seeking')
            .listen(
              (value) {
                _seeking = value == 'yes';
                if (_seeking) _resetHealthEvidence(keepCapabilities: true);
                _emitActual(_activeBinding?.loadId);
              },
              onError: (Object _) {
                _seeking = false;
                _emitActual(_activeBinding?.loadId);
              },
            ),
      );
      _subscriptions.add(
        video.outputProgress.listen(_observeOutputProgress),
      );
      _frameTimings.setFrameTimelineSupported(video.frameTimelineSupported);
      _subscriptions.add(
        video.frameEvents.listen(_frameTimings.accept),
      );
      // 输出已可挂载；媒体探测和首帧准备继续在原生加载链中完成。
      _videoControllerListenable.value = video;
      recordStage('output-created');
      return player;
    } catch (error) {
      recordStage('failed');
      if (player == null) {
        lease?.release();
      } else {
        await _cleanupFailedInitialization(player);
      }
      _diagnostics?.event(
        'player.create.failed',
        level: DiagnosticLogLevel.error,
        details: {'error': error.toString()},
      );
      return null;
    }
  }

  @override
  void sampleMediaClock() {
    _mediaClockSampling.invalidate();
    final player = _player;
    final binding = _activeBinding;
    if (player == null ||
        binding == null ||
        binding.entryId == null ||
        binding.retiring ||
        _shutdownRequested ||
        _nativeLifecycleUnknown ||
        _pendingLoad != null ||
        _mediaClockSeekPending) {
      return;
    }
    final continuity = _mediaClockContinuity;
    final seekSequence = _mediaClockSeekSequence;
    final handleAddress = player.handle;
    final libraryPath = player.nativeLibraryPath;
    bool isCurrent() =>
        !_shutdownRequested &&
        identical(_player, player) &&
        identical(_activeBinding, binding) &&
        !binding.retiring &&
        !_nativeLifecycleUnknown &&
        _pendingLoad == null &&
        !_mediaClockSeekPending &&
        _mediaClockContinuity == continuity &&
        _mediaClockSeekSequence == seekSequence;

    _mediaClockSampling.request(
      () => isCurrent()
          ? sampleNativeMediaClockOnWorker(
              handleAddress: handleAddress,
              libraryPath: libraryPath,
              playlistEntryId: binding.entryId!,
              continuity: continuity,
            )
          : Future.value(null),
      (anchor) {
        if (!isCurrent()) return;
        _samplingSeekConfirmed = true;
        _syncVideoFrameSampling();
        _emit(
          PlaybackRuntimeMediaAnchor(
            runtimeId: runtimeId,
            loadId: binding.loadId,
            seekSequence: seekSequence,
            anchor: anchor,
          ),
        );
      },
    );
  }

  void _subscribePlayerState(Player player) {
    _subscriptions.addAll([
      player.stream.position.listen((_) => sampleMediaClock()),
      player.stream.completed.listen((_) {
        _syncVideoFrameSampling();
        sampleMediaClock();
      }),
      player.stream.playing.listen((value) {
        _playing = value;
        sampleMediaClock();
        _emitActual(_activeBinding?.loadId);
      }),
      player.stream.buffering.listen((value) {
        _buffering = value;
        sampleMediaClock();
        _emitActual(_activeBinding?.loadId);
      }),
      player.stream.duration.listen((_) => _emitActual(_activeBinding?.loadId)),
      // stream.error 包含损坏包、解码回退等诊断；PlayerDiagnostics 和恢复策略
      // 继续处理它们。会话终止由带文件身份的 end-file error 确认。
    ]);
  }

  bool _samplingEnabled = false;
  bool _samplingSeekConfirmed = true;

  void _setDisplaySyncActive(bool active) {
    videoDisplaySyncActive.value = active;
    _frameTimings.setDisplaySyncActive(active);
  }

  void _syncVideoFrameSampling() {
    final output = _videoController;
    final token = _activeBinding?.token;
    final enabled =
        !_shutdownRequested &&
        _playing &&
        !_buffering &&
        !_seeking &&
        !_mediaClockSeekPending &&
        _samplingSeekConfirmed &&
        _player?.state.completed == false &&
        token != null &&
        _activeBinding?.retiring == false &&
        token == _frameTimings.frameState.value.output;
    if (_samplingEnabled == enabled) return;
    _samplingEnabled = enabled;
    final revision = _frameTimings.beginSamplingChange(enabled, Timeline.now);
    if (output != null && token != null) {
      unawaited(
        output
            .setVideoFrameSampling(token, enabled)
            .then((receipt) {
              if (!_shutdownRequested) {
                _frameTimings.completeSamplingChange(revision, receipt);
              }
            })
            .catchError((Object error) {
              if (!_shutdownRequested &&
                  _frameTimings.frameState.value.output == token) {
                _frameTimings.invalidate(Timeline.now);
              }
              _diagnostics?.event(
                'video.sampling.failed',
                details: {'error': '$error'},
              );
            }),
      );
    }
  }

  Future<void> _handleLifecycleHook(
    NativeHookRequest request,
    NativeHookApi api,
  ) async {
    if (_shutdownRequested && request.name != NativeHookName.onUnload) return;
    if (request.name == NativeHookName.onUnload) {
      await _handleUnloadHook(request);
      return;
    }
    if (request.name != NativeHookName.onPreloaded) return;
    if (_bindings[request.playlistEntryId]?.retiring == true) return;
    final pending = _pendingLoad;
    if (pending == null ||
        request.playlistEntryId == null ||
        pending.binding?.entryId != request.playlistEntryId ||
        pending.context.loadId != pending.binding?.loadId) {
      _markNativeLifecycleUnknown(
        'Preloaded hook did not match the active load identity.',
      );
      return;
    }
    if (!api.isValid || !pending.context.isCurrent()) {
      _completeUnknownOutput(pending, 'preloaded-hook-expired');
      return;
    }

    final output = _videoController;
    if (output == null) {
      _completeUnknownOutput(pending, 'video-output-unavailable');
      return;
    }
    pending.context.registerCancellation(() {
      unawaited(output.invalidateOutputGeneration(pending.token));
    });
    try {
      if (pending.plan.configuration.audioOnly) {
        api.setOption('vid', 'no');
        pending.explicitAudioOnly = true;
        return;
      }
      final tracks = api.readVideoTracks();
      pending
        ..hasVideo = tracks.isNotEmpty
        ..preloadedVideoTrackIds = tracks.map((track) => track.id).toSet();
      _hasVideo = pending.hasVideo;
      final allowedTrackId = _allowedVideoTrackId(
        pending.plan,
        tracks,
      );
      final metadata = pending.plan.metadata;
      final confirmedMetadata =
          metadata?.trust == PlaybackMetadataTrust.confirmed ? metadata : null;
      final prepared = await output
          .prepareForLoad(
            pending.token,
            OutputPreparationRequest(
              allowedTrackId: allowedTrackId,
              cropKnownNone: confirmedMetadata?.cropKnownNone == true,
              nativeApi: api,
              sourceWidth: confirmedMetadata?.width,
              sourceHeight: confirmedMetadata?.height,
              pixelAspectRatio: confirmedMetadata?.pixelAspectRatio,
              rotation: confirmedMetadata?.rotation,
            ),
          )
          .timeout(_remaining(pending.context));
      if (!api.isValid || !pending.context.isCurrent()) {
        await output.invalidateOutputGeneration(pending.token);
        return;
      }
      _diagnostics?.event(
        'media.output.preloaded',
        details: {
          'loadId': pending.context.loadId,
          'strategy': prepared.strategy.name,
          'evidence': prepared.evidence.name,
          'trackId': allowedTrackId,
          'trackCount': tracks.length,
          if (tracks.length == 1)
            'selectedBeforeDecode': tracks.single.selected,
        },
      );
      pending.selection = prepared;
      if (prepared.outputEpoch != pending.token.outputEpoch) {
        pending.selection = null;
      }
    } catch (error) {
      pending.selectionFailure = 'output-prepare-failed:${error.runtimeType}';
    }
  }

  String? _allowedVideoTrackId(
    PlaybackPlan plan,
    List<NativeVideoTrackMetadata> tracks,
  ) {
    final explicit = plan.configuration.videoTrackId;
    if (explicit != null) return '$explicit';
    // Auto is unambiguous only when this exact paused file has one video track.
    if (tracks.length == 1) return tracks.single.id;
    return null;
  }

  String? _confirmedVideoTrackId(
    PlaybackPlan plan,
    List<NativeVideoTrackMetadata> tracks,
  ) {
    final activeTracks = tracks
        .where((track) => track.selected == true)
        .toList(growable: false);
    if (activeTracks.length != 1) return null;
    final selectedTrackId = activeTracks.single.id;
    final configuredTrackId = plan.configuration.videoTrackId;
    if (configuredTrackId != null && selectedTrackId != '$configuredTrackId') {
      return null;
    }
    return selectedTrackId;
  }

  Future<void> _handleUnloadHook(NativeHookRequest request) async {
    final entryId = request.playlistEntryId;
    final binding = entryId == null ? null : _bindings[entryId];
    if (entryId == null || binding == null || binding.token == null) {
      _markNativeLifecycleUnknown('Unload hook has no confirmed file binding.');
      return;
    }
    try {
      if (_frameTimings.frameState.value.output == binding.token) {
        _frameTimings.withdraw(Timeline.now);
        _samplingEnabled = false;
      }
      await _videoController?.invalidateOutputGeneration(binding.token!);
      binding.unloaded = true;
      _tryRetireBinding(binding);
    } catch (error) {
      _markNativeLifecycleUnknown('Output invalidation failed: $error');
    }
  }

  void _handleNativeEvent(NativePlayerEvent event) {
    switch (event) {
      case NativeSeekCompleted(:final playlistEntryId, :final observationId):
        final binding = _activeBinding;
        if (!_mediaClockSeekPending ||
            binding == null ||
            binding.retiring ||
            binding.entryId != playlistEntryId ||
            observationId != _mediaClockSeekSequence) {
          return;
        }
        _mediaClockSeekPending = false;
        _mediaClockContinuity++;
        _releaseSeekObservation();
        _syncVideoFrameSampling();
        sampleMediaClock();
      case NativeStartFile(:final playlistEntryId):
        final pending = _pendingLoad;
        if (pending == null || playlistEntryId == null) {
          _markNativeLifecycleUnknown(
            'start-file has no load or entry identity.',
          );
          pending?.fail(const _NativeIdentityFailure('Unknown start-file id.'));
          return;
        }
        if (pending.binding != null) {
          _markNativeLifecycleUnknown(
            'Multiple start-file events in one load.',
          );
          pending.fail(const _NativeIdentityFailure('Duplicate start-file.'));
          return;
        }
        final binding = _NativeFileBinding(
          entryId: playlistEntryId,
          loadId: pending.context.loadId,
          token: pending.token,
        )..retiring = !pending.context.isCurrent();
        pending
          ..binding = binding
          ..started.complete();
        _seekable = null;
        _partiallySeekable = null;
        _lastPublishedCapabilities = null;
        _bindings[playlistEntryId] = binding;
        _activeBinding = binding;
      case NativeFileLoaded(
        :final playlistEntryId,
        :final videoOutputParameters,
        :final videoTracks,
        :final hasAudio,
        :final seekable,
        :final partiallySeekable,
      ):
        if (_bindings[playlistEntryId]?.retiring == true) return;
        final pending = _pendingLoad;
        final binding = pending?.binding;
        if (pending == null ||
            playlistEntryId == null ||
            binding == null ||
            binding.entryId != playlistEntryId) {
          _markNativeLifecycleUnknown(
            'file-loaded identity did not match start-file.',
          );
          pending?.fail(
            const _NativeIdentityFailure('Unknown file-loaded id.'),
          );
          return;
        }
        _seekable = seekable;
        _partiallySeekable = partiallySeekable;
        _updateTrackFacts(
          loadId: binding.loadId,
          videoTracks: videoTracks,
          hasAudio: hasAudio,
        );
        pending.fileLoaded = true;
        unawaited(
          _confirmOutputAfterFileLoaded(
            pending,
            videoOutputParameters,
            videoTracks,
          ),
        );
      case NativeVideoOutputParametersChanged(
        :final playlistEntryId,
        :final videoOutputParameters,
      ):
        final pending = _pendingLoad;
        if (pending == null ||
            playlistEntryId == null ||
            pending.binding?.entryId != playlistEntryId ||
            !pending.context.isCurrent()) {
          return;
        }
        if (_hasOutputGeometry(videoOutputParameters) &&
            !pending.outputGeometry.isCompleted) {
          pending.outputGeometry.complete(videoOutputParameters);
        }
      case NativeTracksChanged(
        :final playlistEntryId,
        :final videoTracks,
        :final hasAudio,
      ):
        final active = _activeBinding;
        if (active == null || active.token == null) return;
        if (playlistEntryId == null) {
          _updateTrackFacts(
            loadId: active.loadId,
            videoTracks: null,
            hasAudio: null,
          );
          return;
        }
        final binding = _bindings[playlistEntryId];
        if (binding == null || !identical(binding, active)) return;
        _updateTrackFacts(
          loadId: binding.loadId,
          videoTracks: videoTracks,
          hasAudio: hasAudio,
        );
      case NativeEndFile(:final playlistEntryId, :final reason, :final error):
        if (playlistEntryId == null) {
          _markNativeLifecycleUnknown(
            'end-file has no playlist entry identity.',
          );
          _pendingLoad?.fail(
            const _NativeIdentityFailure('Unknown end-file id.'),
          );
          return;
        }
        final binding = _bindings[playlistEntryId];
        if (binding == null) return;
        binding.endFileSeen = true;
        _tryRetireBinding(binding);
        final pending = _pendingLoad;
        if (pending != null && identical(pending.binding, binding)) {
          pending.handleEnd(reason, error);
        }
        if (reason == NativeEndFileReason.eof &&
            identical(binding, _activeBinding)) {
          _emit(
            PlaybackRuntimeEnded(
              runtimeId: runtimeId,
              loadId: binding.loadId,
            ),
          );
        } else if (reason == NativeEndFileReason.error &&
            identical(binding, _activeBinding)) {
          final failure = PlaybackFailure(
            category: PlaybackFailureCategory.source,
            operation: 'end-file',
            stage: PlaybackStage.observing,
            recoverable: true,
            cause: 'Native end-file error $error.',
          );
          _emit(
            PlaybackRuntimeFailure(
              runtimeId: runtimeId,
              loadId: binding.loadId,
              failure: failure,
            ),
          );
        }
      case NativeEventQueueOverflow():
        _markNativeLifecycleUnknown('Native event queue overflowed.');
        _pendingLoad?.fail(
          const _NativeIdentityFailure('Native event queue overflowed.'),
        );
      case NativeEventBatchDrained(:final batchId):
        if (batchId > _lastBatchId) _lastBatchId = batchId;
    }
  }

  Future<void> _confirmOutputAfterFileLoaded(
    _PendingNativeLoad pending,
    NativeVideoOutputParameters? videoOutputParameters,
    List<NativeVideoTrackMetadata>? videoTracks,
  ) async {
    if (pending.output.isCompleted) return;
    if (!pending.context.isCurrent() ||
        !identical(_pendingLoad, pending) ||
        pending.binding?.token != pending.token) {
      _completeUnknownOutput(pending, 'file-loaded-load-no-longer-current');
      return;
    }

    final selection = pending.selection;
    final preloadedIds = pending.preloadedVideoTrackIds;
    if (preloadedIds != null && videoTracks != null) {
      final loadedIds = videoTracks.map((track) => track.id).toSet();
      if (preloadedIds.length != loadedIds.length ||
          !preloadedIds.containsAll(loadedIds)) {
        _completeUnknownOutput(
          pending,
          'preloaded-and-file-loaded-track-list-mismatch',
        );
        return;
      }
    }
    if (pending.explicitAudioOnly) {
      _hasVideo = false;
      _completeOutput(
        pending,
        PlaybackOutputPreparation(
          strategy: PlaybackOutputStrategy.noVideo,
          evidence: 'explicit-audio-only',
          outputEpoch: pending.token.outputEpoch,
          hasVideo: false,
        ),
      );
      return;
    }
    if (videoTracks?.isEmpty == true &&
        selection?.strategy == OutputLoadSelectionStrategy.selectedVideo) {
      _completeUnknownOutput(
        pending,
        'preloaded-and-file-loaded-track-list-mismatch',
      );
      return;
    }
    if (selection?.strategy == OutputLoadSelectionStrategy.noVideo &&
        videoTracks?.isNotEmpty == true) {
      _completeUnknownOutput(
        pending,
        'preloaded-and-file-loaded-track-list-mismatch',
      );
      return;
    }
    if (selection?.strategy == OutputLoadSelectionStrategy.noVideo ||
        videoTracks?.isEmpty == true) {
      _hasVideo = false;
      pending.hasVideo = false;
      final evidence = videoTracks?.isEmpty == true
          ? 'native-track-list-no-video'
          : selection!.evidence.name;
      _completeOutput(
        pending,
        PlaybackOutputPreparation(
          strategy: PlaybackOutputStrategy.noVideo,
          evidence: evidence,
          outputEpoch: pending.token.outputEpoch,
          hasVideo: false,
        ),
      );
      return;
    }
    if (videoTracks == null) {
      _completeUnknownOutput(pending, 'file-loaded-track-list-unavailable');
      return;
    }
    pending.hasVideo = true;
    _hasVideo = true;

    final output = _videoController;
    if (output == null) {
      _completeUnknownOutput(pending, 'video-output-unavailable');
      return;
    }
    final selectionEvidence =
        selection?.evidence.name ??
        pending.selectionFailure ??
        'no-preloaded-selection';
    final allowedTrackId = _confirmedVideoTrackId(
      pending.plan,
      videoTracks,
    );
    if (allowedTrackId == null) {
      _completeUnknownOutput(
        pending,
        '$selectionEvidence+file-loaded-track-selection-unconfirmed',
      );
      return;
    }
    try {
      // FILE_LOADED 可以先于首份输出参数到达；保持暂停，等待同一文件的事实。
      if (!_hasOutputGeometry(videoOutputParameters)) {
        videoOutputParameters = await pending.waitForGeometry(
          _remaining(pending.context),
          live: pending.plan.timeline.kind == PlaybackTimelineKind.live,
        );
        if (!pending.context.isCurrent() || !identical(_pendingLoad, pending)) {
          _completeUnknownOutput(pending, 'output-geometry-expired');
          return;
        }
      }
      final confirmation = await output
          .confirmFileLoaded(
            pending.token,
            videoOutputParameters,
            videoTracks: videoTracks,
            allowedTrackId: allowedTrackId,
          )
          .timeout(_remaining(pending.context));
      if (!pending.context.isCurrent() ||
          !identical(_pendingLoad, pending) ||
          confirmation.outputEpoch != pending.token.outputEpoch) {
        await output.invalidateOutputGeneration(pending.token);
        _completeUnknownOutput(pending, 'file-loaded-confirmation-expired');
        return;
      }
      if (confirmation.strategy == OutputPreparationStrategy.noVideo) {
        _hasVideo = false;
        _completeOutput(
          pending,
          PlaybackOutputPreparation(
            strategy: PlaybackOutputStrategy.noVideo,
            evidence: confirmation.evidence.name,
            outputEpoch: confirmation.outputEpoch,
            hasVideo: false,
          ),
        );
        return;
      }
      if (confirmation.strategy != OutputPreparationStrategy.prepared &&
          confirmation.strategy != OutputPreparationStrategy.legacyAttached) {
        _completeUnknownOutput(
          pending,
          '$selectionEvidence+${confirmation.evidence.name}',
        );
        return;
      }
      final attached = await output
          .waitForOutputAttach(pending.token)
          .timeout(_remaining(pending.context));
      if (!pending.context.isCurrent() ||
          !identical(_pendingLoad, pending) ||
          attached.outputEpoch != pending.token.outputEpoch ||
          (attached.strategy != OutputPreparationStrategy.prepared &&
              attached.strategy != OutputPreparationStrategy.legacyAttached)) {
        _completeUnknownOutput(pending, attached.evidence.name);
        return;
      }
      var outputWidth =
          attached.geometry?.width ?? confirmation.geometry?.width;
      var outputHeight =
          attached.geometry?.height ?? confirmation.geometry?.height;
      if (Platform.isWindows) {
        final target = VideoOutputSizePolicy.fitWithinLimit(
          source: VideoOutputSizePolicy.videoDisplaySize(
            VideoParams(
              dw:
                  videoOutputParameters?.displayWidth ??
                  videoOutputParameters?.width,
              dh:
                  videoOutputParameters?.displayHeight ??
                  videoOutputParameters?.height,
              rotate: videoOutputParameters?.rotation,
            ),
          ),
          limit: WindowsVideoOutputLimit.detected,
        );
        if (target != null) {
          // 在暂停加载阶段完成限幅，页面挂载后直接播放最终尺寸的纹理。
          await output
              .setSize(width: target.width, height: target.height)
              ?.timeout(_remaining(pending.context));
          if (!pending.context.isCurrent() ||
              !identical(_pendingLoad, pending)) {
            _completeUnknownOutput(pending, 'output-size-expired');
            return;
          }
          outputWidth = target.width;
          outputHeight = target.height;
        }
      }
      _completeOutput(
        pending,
        PlaybackOutputPreparation(
          strategy: _playbackOutputStrategy(attached.strategy),
          evidence:
              '$selectionEvidence+'
              '${confirmation.evidence.name}+${attached.evidence.name}',
          outputEpoch: attached.outputEpoch,
          width: outputWidth,
          height: outputHeight,
          hasVideo: true,
        ),
      );
    } on PlaybackFailure catch (failure) {
      pending.failLoad(failure, 'video-output-geometry-unavailable');
      _diagnostics?.event(
        'media.startup.failed',
        level: DiagnosticLogLevel.error,
        details: {
          'loadId': pending.context.loadId,
          'operation': failure.operation,
          'cause': failure.cause,
        },
      );
    } catch (error) {
      _completeUnknownOutput(
        pending,
        'file-loaded-output-failed:${error.runtimeType}',
      );
    }
  }

  bool _hasOutputGeometry(NativeVideoOutputParameters? value) =>
      value != null &&
      (value.width ?? 0) > 0 &&
      (value.height ?? 0) > 0 &&
      value.pixelAspectRatio != null &&
      value.rotation != null;

  void _tryRetireBinding(_NativeFileBinding binding) {
    if (binding.endFileSeen && binding.unloaded) {
      if (!binding.retired.isCompleted) binding.retired.complete();
    }
  }

  void _completeOutput(
    _PendingNativeLoad pending,
    PlaybackOutputPreparation output,
  ) {
    if (pending.output.isCompleted) return;
    pending.output.complete(output);
    pending.resultMaybeComplete();
  }

  void _completeUnknownOutput(_PendingNativeLoad pending, String evidence) {
    _completeOutput(
      pending,
      PlaybackOutputPreparation(
        strategy: PlaybackOutputStrategy.unknown,
        evidence: evidence,
        outputEpoch: pending.token.outputEpoch,
        hasVideo: pending.hasVideo,
      ),
    );
  }

  void _markNativeLifecycleUnknown(String reason) {
    if (_nativeLifecycleUnknown) return;
    _nativeLifecycleUnknown = true;
    _diagnostics?.event(
      'native.lifecycle.unknown',
      level: DiagnosticLogLevel.error,
      details: {'reason': reason, 'batchId': _lastBatchId},
    );
  }

  PlaybackOutputStrategy _playbackOutputStrategy(
    OutputPreparationStrategy strategy,
  ) => switch (strategy) {
    OutputPreparationStrategy.prepared => PlaybackOutputStrategy.prepared,
    OutputPreparationStrategy.noVideo => PlaybackOutputStrategy.noVideo,
    OutputPreparationStrategy.legacyAttached =>
      PlaybackOutputStrategy.legacyAttached,
    OutputPreparationStrategy.unknown => PlaybackOutputStrategy.unknown,
  };

  SubtitleTrack _nativeSubtitleTrack(PlaybackSubtitleTrack? track) {
    if (track == null || track.id == 'auto') return SubtitleTrack.auto();
    if (track.id == 'no' && !track.uri) return SubtitleTrack.no();
    if (track.uri) {
      return SubtitleTrack.uri(
        track.id,
        title: track.title,
        language: track.language,
      );
    }
    return SubtitleTrack(
      track.id,
      track.title,
      track.language,
    );
  }

  void _handleRuntimeNativeError(Object error) {
    _markNativeLifecycleUnknown('Native event stream error: $error');
    _pendingLoad?.fail(error);
  }

  void _observePts(String kind, String? raw) {
    final binding = _activeBinding;
    if (binding == null || binding.token == null || raw == null) return;
    final value = double.tryParse(raw);
    if (value == null || !value.isFinite) return;
    final previous = _lastPts[kind];
    _lastPts[kind] = value;
    if (previous == null || value <= previous || _seeking) return;
    final now = _activeNow();
    if (kind == 'audio') {
      _lastAudioPtsAdvance = now;
      _hasAudio = true;
    }
    _scheduleHealthExpiry();
    _emitCapabilities(binding.loadId);
    _emitActual(binding.loadId);
  }

  void _observeVideoFrameNumber(String? raw) {
    final binding = _activeBinding;
    if (binding == null || binding.token == null || raw == null) return;
    final frameNumber = double.tryParse(raw);
    if (frameNumber == null || !frameNumber.isFinite) return;
    final previous = _lastVideoFrameNumber;
    _lastVideoFrameNumber = frameNumber;
    if (previous == null || frameNumber <= previous || _seeking) return;
    _lastVideoFrameAdvance = _activeNow();
    _scheduleHealthExpiry();
    _emitCapabilities(binding.loadId);
    _emitActual(binding.loadId);
  }

  void _observeOutputProgress(VideoOutputProgress progress) {
    final binding = _activeBinding;
    if (binding == null ||
        binding.token == null ||
        progress.token != binding.token ||
        progress.token.runtimeId != runtimeId ||
        progress.token.loadId != binding.loadId ||
        progress.consumedAtMonotonicUs.isEmpty) {
      return;
    }
    if (!_frameTimings.recordConsumed(progress.consumedAtMonotonicUs)) return;
    _lastVideoFrameConsumed = _activeNow();
    _scheduleHealthExpiry();
    _emitActual(binding.loadId);
  }

  void _updateTrackFacts({
    required int loadId,
    required List<NativeVideoTrackMetadata>? videoTracks,
    required bool? hasAudio,
  }) {
    _hasAudio = hasAudio;
    if (videoTracks == null) {
      _hasVideo = null;
      _selectedVideoTrack = null;
      _selectedVideoFps = null;
    } else if (videoTracks.isEmpty) {
      _hasVideo = false;
      _selectedVideoTrack = false;
      _selectedVideoFps = null;
    } else {
      _hasVideo = true;
      final selected = videoTracks
          .where((track) => track.selected == true)
          .toList(growable: false);
      if (selected.length == 1) {
        _selectedVideoTrack = true;
        _selectedVideoFps = selected.single.demuxFps;
      } else {
        _selectedVideoTrack = null;
        _selectedVideoFps = null;
      }
    }
    _emitCapabilities(loadId);
  }

  bool? _audioProgressing(Duration now) {
    if (_hasAudio == false) return false;
    if (_hasAudio != true) return null;
    return _fresh(_lastAudioPtsAdvance, now) &&
        !_buffering &&
        _playing &&
        !_seeking;
  }

  bool? _videoProgressing(Duration now) {
    if (_hasVideo == false) return false;
    if (_hasVideo != true) return null;
    final frameRate = _selectedVideoFps;
    if (_selectedVideoTrack != true ||
        frameRate == null ||
        !frameRate.isFinite ||
        frameRate <= 0) {
      return null;
    }
    // estimated-frame-number derives from playback position in the bundled
    // mpv. Pair it with a token-matched Flutter-consumed frame, and only use
    // it for a selected video track with a known positive frame rate.
    return _fresh(_lastVideoFrameAdvance, now) &&
        _fresh(_lastVideoFrameConsumed, now) &&
        !_buffering &&
        _playing &&
        !_seeking;
  }

  bool _fresh(Duration? timestamp, Duration now) =>
      timestamp != null && now - timestamp <= const Duration(seconds: 2);

  void _scheduleHealthExpiry() {
    final now = _activeNow();
    final timestamps = [
      if (_hasAudio == true) _lastAudioPtsAdvance,
      if (_hasVideo == true) ...[
        _lastVideoFrameAdvance,
        _lastVideoFrameConsumed,
      ],
    ].whereType<Duration>().toList();
    if (timestamps.isEmpty) return;
    final futureExpiries = timestamps
        .map((value) => value + const Duration(seconds: 2, microseconds: 1))
        .where((expiry) => expiry > now)
        .toList();
    if (futureExpiries.isEmpty) {
      _healthExpiry?.cancel();
      _healthExpiry = null;
      _healthExpiryDeadline = null;
      return;
    }
    final expires = futureExpiries.reduce(
      (left, right) => left < right ? left : right,
    );
    final currentDeadline = _healthExpiryDeadline;
    if (_healthExpiry?.isActive == true &&
        currentDeadline != null &&
        currentDeadline <= expires) {
      return;
    }
    _healthExpiry?.cancel();
    _healthExpiryDeadline = expires;
    _healthExpiry = Timer(
      expires - now,
      () {
        _healthExpiry = null;
        _healthExpiryDeadline = null;
        _emitActual(_activeBinding?.loadId);
      },
    );
  }

  void _resetHealthEvidence({bool keepCapabilities = false}) {
    _healthExpiry?.cancel();
    _healthExpiry = null;
    _healthExpiryDeadline = null;
    _lastPts.clear();
    _lastAudioPtsAdvance = null;
    _lastVideoFrameAdvance = null;
    _lastVideoFrameConsumed = null;
    _lastVideoFrameNumber = null;
    _frameTimings.invalidate(Timeline.now);
    if (!keepCapabilities) {
      _hasVideo = null;
      _hasAudio = null;
      _selectedVideoTrack = null;
      _selectedVideoFps = null;
    }
    _lastPublishedActual = null;
  }

  void _emitActual(int? loadId) {
    _syncVideoFrameSampling();
    final player = _player;
    if (player == null || loadId == null) return;
    final now = _activeNow();
    final actual = PlaybackActual(
      playing: player.state.playing,
      buffering: player.state.buffering,
      seeking: _seeking,
      position: player.state.position,
      duration: player.state.duration,
      audioProgressing: _audioProgressing(now),
      videoProgressing: _videoProgressing(now),
    );
    final previous = _lastPublishedActual;
    _lastPublishedActual = actual;
    if (previous == null ||
        previous.playing != actual.playing ||
        previous.buffering != actual.buffering ||
        previous.seeking != actual.seeking ||
        previous.duration != actual.duration ||
        previous.audioProgressing != actual.audioProgressing ||
        previous.videoProgressing != actual.videoProgressing) {
      _emit(
        PlaybackRuntimeStateChanged(
          runtimeId: runtimeId,
          loadId: loadId,
          actual: actual,
        ),
      );
    }
    _scheduleHealthExpiry();
  }

  void _emitCapabilities(int? loadId) {
    if (loadId == null) return;
    final capabilities = _currentCapabilities();
    final previous = _lastPublishedCapabilities;
    if (previous != null &&
        previous.hasVideo == capabilities.hasVideo &&
        previous.hasAudio == capabilities.hasAudio &&
        previous.seekSupport == capabilities.seekSupport &&
        previous.seekStart == capabilities.seekStart &&
        previous.seekEnd == capabilities.seekEnd) {
      return;
    }
    _lastPublishedCapabilities = capabilities;
    _emit(
      PlaybackRuntimeCapabilitiesChanged(
        runtimeId: runtimeId,
        loadId: loadId,
        capabilities: capabilities,
      ),
    );
  }

  PlaybackCapabilities _currentCapabilities() {
    final duration = _player?.state.duration;
    final seekPolicy = _activePlan?.timeline.seekPolicy;
    final seekSupport = switch (seekPolicy) {
      PlaybackSeekPolicy.disabled => PlaybackSeekSupport.unsupported,
      PlaybackSeekPolicy.unknown || null => PlaybackSeekSupport.unknown,
      PlaybackSeekPolicy.allowed when _seekable == false =>
        PlaybackSeekSupport.unsupported,
      PlaybackSeekPolicy.allowed
          when _seekable == true &&
              _partiallySeekable == false &&
              duration != null &&
              duration > Duration.zero =>
        PlaybackSeekSupport.supported,
      PlaybackSeekPolicy.allowed => PlaybackSeekSupport.unknown,
    };
    return PlaybackCapabilities(
      hasVideo: _hasVideo,
      hasAudio: _hasAudio,
      seekSupport: seekSupport,
      seekStart: seekSupport == PlaybackSeekSupport.supported
          ? Duration.zero
          : null,
      seekEnd: seekSupport == PlaybackSeekSupport.supported ? duration : null,
    );
  }

  void _emit(PlaybackRuntimeEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  Player? _usablePlayer(PlaybackExecutionContext context) {
    if (_shutdownRequested || !context.isCurrent()) return null;
    final player = _player;
    if (player == null || player.disposed || _activeBinding == null) {
      return null;
    }
    return player;
  }

  Duration _remaining(PlaybackExecutionContext context) {
    final value = context.deadline - context.monotonicNow();
    if (value <= Duration.zero) {
      throw TimeoutException('Playback request deadline expired.');
    }
    return value;
  }

  PlaybackRuntimeLoadResult _supersededLoad() =>
      const PlaybackRuntimeLoadResult(
        loaded: false,
        output: PlaybackOutputPreparation(
          strategy: PlaybackOutputStrategy.unknown,
          evidence: 'superseded',
          outputEpoch: 0,
        ),
      );

  PlaybackRuntimeLoadResult _loadFailure(
    PlaybackFailureCategory category,
    String operation,
    Object error,
  ) => PlaybackRuntimeLoadResult(
    loaded: false,
    output: const PlaybackOutputPreparation(
      strategy: PlaybackOutputStrategy.unknown,
      evidence: 'load-failed',
      outputEpoch: 0,
    ),
    failure: _failure(category, operation, error),
  );

  PlaybackFailure _failure(
    PlaybackFailureCategory category,
    String operation,
    Object error,
  ) => PlaybackFailure(
    category: category,
    operation: operation,
    stage: PlaybackStage.opening,
    recoverable:
        category == PlaybackFailureCategory.timeout ||
        category == PlaybackFailureCategory.source,
    cause: error.toString(),
  );

  Future<PlaybackShutdownResult> _shutdown() async {
    final watch = Stopwatch()..start();
    var previousStageUs = 0;
    void recordStage(String stage) {
      if (_player == null) return;
      final elapsed = watch.elapsedMicroseconds;
      Diagnostics.instance.playerLog(
        DiagnosticLogLevel.info,
        'player',
        'runtime.shutdown.$stage',
        details: {
          'runtimeId': runtimeId,
          'durationUs': elapsed,
          'stageDurationUs': elapsed - previousStageUs,
          'loadId': _activeBinding?.loadId,
          'entryId': _activeBinding?.entryId,
          'outputEpoch': _activeBinding?.token?.outputEpoch,
          'endFileSeen': _activeBinding?.endFileSeen,
          'unloaded': _activeBinding?.unloaded,
          'nativeLifecycleUnknown': _nativeLifecycleUnknown,
          'batchId': _lastBatchId,
        },
      );
      previousStageUs = elapsed;
    }

    recordStage('begin');
    _shutdownRequested = true;
    _syncVideoFrameSampling();
    _healthExpiry?.cancel();
    try {
      final player = _player;
      if (player == null) {
        await _closeRuntimeStreams();
        if (!_released.isCompleted) _released.complete();
        return const PlaybackShutdownResult.released();
      }
      final binding = _activeBinding;
      if (!player.disposed && binding != null) {
        if (binding.entryId == null || binding.token == null) {
          return PlaybackShutdownResult.cleanupIncomplete(
            _failure(
              PlaybackFailureCategory.disposal,
              'shutdown-unload-barrier',
              StateError('Active file identity is unknown.'),
            ),
          );
        }
        if (!(binding.endFileSeen && binding.unloaded)) {
          recordStage('stopping-file');
          await player.stop();
          // The session's single shutdown deadline bounds the caller result.
          // Keep this cleanup chain alive until native stop and unload facts
          // actually arrive; a late barrier must still complete released.
          recordStage('waiting-for-file-retirement');
          await binding.retired.future;
        }
        recordStage('invalidating-output');
        await _videoController?.invalidateOutputGeneration(binding.token!);
        _activeBinding = null;
      }

      recordStage('file-retired');
      _diagnostics?.dispose();
      _diagnostics = null;
      recordStage('releasing-subscriptions');
      for (final subscription in _subscriptions) {
        await subscription.cancel();
      }
      _subscriptions.clear();
      await _hookRegistration?.dispose();
      _hookRegistration = null;
      recordStage('subscriptions-released');
      recordStage('waiting-for-media-clock');
      await _mediaClockSampling.close();
      recordStage('releasing-output');
      await _videoController?.releaseOutput();
      recordStage('output-released');
      // Player 释放会归还运行时槽；下一 owner 取得槽前先恢复本次亲和性。
      _restoreRasterScheduling();
      try {
        recordStage('disposing-player');
        await player.dispose();
        recordStage('player-disposed');
        await player.released;
        recordStage('released');
      } catch (error) {
        return PlaybackShutdownResult.cleanupIncomplete(
          _failure(PlaybackFailureCategory.disposal, 'player-dispose', error),
        );
      }
      _player = null;
      _videoController = null;
      _videoControllerListenable.value = null;
      await _closeRuntimeStreams();
      if (!_released.isCompleted) _released.complete();
      return const PlaybackShutdownResult.released();
    } on TimeoutException catch (error) {
      return PlaybackShutdownResult.cleanupIncomplete(
        _failure(PlaybackFailureCategory.timeout, 'shutdown', error),
      );
    } catch (error) {
      return PlaybackShutdownResult.cleanupIncomplete(
        _failure(PlaybackFailureCategory.disposal, 'shutdown', error),
      );
    } finally {
      _restoreRasterScheduling();
    }
  }

  void _restoreRasterScheduling() {
    final scheduling = _rasterScheduling;
    _rasterScheduling = null;
    try {
      scheduling?.restore();
    } catch (_) {
      Diagnostics.instance.playerLog(
        DiagnosticLogLevel.warning,
        'player',
        'raster.scheduling.restore.failed',
      );
    }
  }

  Future<void> _cleanupFailedInitialization(Player player) async {
    _diagnostics?.dispose();
    _diagnostics = null;
    try {
      for (final subscription in _subscriptions) {
        await subscription.cancel();
      }
      _subscriptions.clear();
      _mediaClockSampling.invalidate();
      await _mediaClockSampling.idle;
      await _hookRegistration?.dispose();
      await _videoController?.releaseOutput();
      _restoreRasterScheduling();
      if (!player.disposed) await player.dispose();
      await player.released;
      _player = null;
      _videoController = null;
      if (!_released.isCompleted && _shutdownRequested) _released.complete();
    } catch (_) {
      // An unconfirmed native release keeps the process-wide slot occupied.
    } finally {
      _restoreRasterScheduling();
    }
  }

  Future<void> _closeRuntimeStreams() async {
    _videoControllerListenable.value = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    if (!_events.isClosed) unawaited(_events.close());
    _frameTimings.invalidate(Timeline.now);
    videoDisplaySyncActive.value = false;
    unawaited(_seekSubmissionChanges.close());
    _frameTimings.dispose();
    videoDisplaySyncActive.dispose();
    _videoControllerListenable.dispose();
  }
}

class _PendingNativeLoad extends NativeLoadReadiness {
  _PendingNativeLoad({
    required this.plan,
    required this.context,
    required this.token,
  }) : super(outputEpoch: token.outputEpoch);

  final PlaybackPlan plan;
  final PlaybackExecutionContext context;
  final OutputOperationToken token;
  final Completer<void> started = Completer<void>();
  _NativeFileBinding? binding;
  OutputLoadSelectionResult? selection;
  String? selectionFailure;
  Set<String>? preloadedVideoTrackIds;
  bool explicitAudioOnly = false;

  void fail(Object error) {
    if (!output.isCompleted) {
      output.complete(
        PlaybackOutputPreparation(
          strategy: PlaybackOutputStrategy.unknown,
          evidence: 'native-file-identity-unknown',
          outputEpoch: token.outputEpoch,
          hasVideo: hasVideo,
        ),
      );
    }
    if (!result.isCompleted) {
      result.complete(
        PlaybackRuntimeLoadResult(
          loaded: false,
          output: PlaybackOutputPreparation(
            strategy: PlaybackOutputStrategy.unknown,
            evidence: 'native-file-identity-unknown',
            outputEpoch: token.outputEpoch,
            hasVideo: hasVideo,
          ),
          failure: PlaybackFailure(
            category: PlaybackFailureCategory.capability,
            operation: 'native-file-identity',
            stage: PlaybackStage.opening,
            recoverable: false,
            cause: error.toString(),
          ),
        ),
      );
    }
  }
}

class _NativeFileBinding {
  _NativeFileBinding({
    required this.entryId,
    required this.loadId,
    required this.token,
  });

  final int? entryId;
  final int loadId;
  final OutputOperationToken? token;
  final Completer<void> retired = Completer<void>();
  bool endFileSeen = false;
  bool unloaded = false;
  bool retiring = false;
}

class _NativeIdentityFailure implements Exception {
  const _NativeIdentityFailure(this.message);

  final String message;

  @override
  String toString() => message;
}
