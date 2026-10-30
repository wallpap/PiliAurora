import 'dart:async';
import 'dart:developer' show Timeline;

import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/utils/playback_load_queue.dart';

/// Owns playback intent, request acceptance and the only command path to a runtime.
/// A session is local to one controller; native resource reuse is guarded by
/// [PlaybackRuntimeSlot], not by reusing this object across UI lifetimes.
class PlaybackSession implements PlaybackMediaClock {
  PlaybackSession({
    required PlaybackRuntimePort runtime,
    Duration Function()? monotonicNow,
    int Function()? mediaClockNowUs,
    this.loadBudget = const Duration(seconds: 30),
    this.commandBudget = const Duration(seconds: 5),
    this.shutdownBudget = const Duration(seconds: 10),
  }) : _runtime = runtime,
       _now = monotonicNow ?? _defaultClock,
       _mediaClockNowUs = mediaClockNowUs ?? (() => Timeline.now),
       _operations = PlaybackOperationScheduler(
         now: monotonicNow ?? _defaultClock,
       ) {
    _runtimeSubscription = runtime.events.listen(
      _handleRuntimeEvent,
      onError: (Object error, StackTrace stackTrace) {
        _publishFailure(
          PlaybackFailure(
            category: PlaybackFailureCategory.unknown,
            operation: 'runtime.events',
            stage: _stage,
            recoverable: false,
            cause: error.toString(),
          ),
        );
      },
    );
    unawaited(
      runtime.released.then<void>(
        (_) => _handleReleased(),
        onError: (Object error, StackTrace stackTrace) =>
            _handleReleaseFailure(error),
      ),
    );
  }

  static final Stopwatch _clock = Stopwatch()..start();
  static Duration _defaultClock() => _clock.elapsed;

  final PlaybackRuntimePort _runtime;
  final Duration Function() _now;
  final int Function() _mediaClockNowUs;
  final PlaybackOperationScheduler _operations;
  final Duration loadBudget;
  final Duration commandBudget;
  final Duration shutdownBudget;
  final List<PlaybackOwner> _owners = [];
  final Map<PlaybackOwner, Set<PlaybackInhibitorToken>> _ownerInhibitors = {};
  final Set<PlaybackInhibitorToken> _sessionInhibitors = {};
  final Map<PlaybackOwner, List<_SnapshotSubscriber>> _subscribers = {};
  final Map<PlaybackConfigurationKey, int> _configurationRevisions = {};
  final Set<PlaybackConfigurationKey> _configurationPending = {};
  final Map<int, Completer<CommandResult>> _playingWaiters = {};
  final StreamController<PlaybackSessionTrace> _traceController =
      StreamController<PlaybackSessionTrace>.broadcast(sync: true);

  StreamSubscription<PlaybackRuntimeEvent>? _runtimeSubscription;
  PlaybackOwner? _activeOwner;
  PlaybackPlan? _currentPlan;
  PlaybackPlan? _lastLoadPlan;
  PlaybackOwner? _lastLoadOwner;
  bool _runtimePositionAvailable = false;
  PlaybackConfiguration _desiredConfiguration = PlaybackConfiguration();
  PlaybackConfiguration _appliedConfiguration = PlaybackConfiguration();
  PlaybackActual _actual = const PlaybackActual();
  PlaybackCapabilities _capabilities = const PlaybackCapabilities();
  PlaybackPresentation _presentation = const PlaybackPresentation();
  PlaybackFailure? _failure;
  PlaybackAction? _pendingAction;
  PlaybackPhase _phase = PlaybackPhase.idle;
  PlaybackStage _stage = PlaybackStage.idle;
  int _snapshotVersion = 0;
  int _nextOwnerId = 1;
  int _nextInhibitorId = 1;
  int _nextActionId = 1;
  int _requestId = 0;
  int _loadId = 0;
  int _seekSequence = 0;
  int? _pendingSeekSequence;
  Completer<void>? _seekWaitCancelled;
  PlaybackMediaAnchor? _mediaAnchor;
  final _mediaAnchors = StreamController<PlaybackMediaAnchor?>.broadcast(
    sync: true,
  );

  @override
  PlaybackMediaAnchor? get currentMediaAnchor => _mediaAnchor;

  @override
  Stream<PlaybackMediaAnchor?> get mediaAnchors => _mediaAnchors.stream;

  bool get _mediaClockMayAdvance =>
      _phase == PlaybackPhase.ready &&
      _actual.playing != false &&
      _actual.buffering != true &&
      _actual.seeking != true;

  void _freezeMediaAnchor({bool refreshObservedAt = false}) {
    final anchor = _mediaAnchor;
    if (anchor == null ||
        !anchor.ready ||
        (!anchor.advancing && !refreshObservedAt)) {
      return;
    }
    // 状态通知先冻结时钟，属性采样随后校准；时间仍使用媒体锚点的时钟域。
    final now = _mediaClockNowUs();
    final frozen = PlaybackMediaAnchor(
      positionUs: anchor.positionAt(now)!,
      observedAtUs: now,
      effectiveRate: anchor.effectiveRate,
      advancing: false,
      ready: anchor.ready,
      continuity: anchor.continuity,
      validForUs: anchor.validForUs,
    );
    _mediaAnchor = frozen;
    _mediaAnchors.add(frozen);
  }

  void _invalidateMediaAnchor() {
    _pendingSeekSequence = null;
    final waiting = _seekWaitCancelled;
    _seekWaitCancelled = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
    if (_mediaAnchor == null) return;
    _mediaAnchor = null;
    _mediaAnchors.add(null);
  }

  int _intentRevision = 0;
  int _keepAliveCount = 0;
  int? _writerLoadRequestId;
  bool _writerRunning = false;
  Completer<void>? _writerDrain;
  bool _closingRequested = false;
  bool _disposed = false;
  bool _shutdownStarted = false;
  Future<PlaybackShutdownResult>? _shutdownTask;
  _AcceptedRequest? _acceptedRequest;
  _RecoveryIncident? _recoveryIncident;
  Duration? _healthySince;
  Timer? _healthyCheck;
  PlaybackSnapshot _snapshot = PlaybackSnapshot(
    snapshotVersion: 0,
    phase: PlaybackPhase.idle,
    stage: PlaybackStage.idle,
    intent: const PlaybackIntent(),
    actual: const PlaybackActual(),
    capabilities: const PlaybackCapabilities(),
    presentation: const PlaybackPresentation(),
  );

  int get revision => _requestId;
  int get requestId => _requestId;
  int get loadId => _loadId;
  bool get isLoading =>
      _phase == PlaybackPhase.loading ||
      _phase == PlaybackPhase.recovering ||
      _phase == PlaybackPhase.closing;
  bool get isDisposed => _disposed || _closingRequested;
  PlaybackSnapshot get currentSnapshot => _snapshot;
  PlaybackPlan? get currentPlan => _currentPlan;
  Stream<PlaybackSessionTrace> get trace => _traceController.stream;
  Future<void> get drained => _operations.drained;

  PlaybackOwner attach() {
    if (_closingRequested) {
      return PlaybackOwner._(this, _nextOwnerId++).._closed = true;
    }
    final previous = _activeOwner;
    if (previous != null) {
      previous
        ..invalidateRequests()
        .._requiresLoad = true;
    }
    _invalidateMediaAnchor();
    _supersedeAcceptedRequest();
    _operations.prioritizeLoad();
    final owner = PlaybackOwner._(this, _nextOwnerId++);
    _owners.add(owner);
    _ownerInhibitors[owner] = <PlaybackInhibitorToken>{};
    _activeOwner = owner;
    _updateRecoveryClock();
    _intentRevision++;
    _settlePlayingWaiters(const CommandResult.superseded());
    _publish();
    _scheduleWriterIfReady();
    return owner;
  }

  PlaybackInhibitorToken? acquireSessionInhibitor(
    PlaybackInhibitorSource source,
  ) {
    if (_closingRequested ||
        _disposed ||
        (source != PlaybackInhibitorSource.audioFocus &&
            source != PlaybackInhibitorSource.backgroundPolicy)) {
      return null;
    }
    final token = PlaybackInhibitorToken(
      source: source,
      id: _nextInhibitorId++,
    );
    _sessionInhibitors.add(token);
    _updateRecoveryClock();
    _healthySince = null;
    _healthyCheck?.cancel();
    _healthyCheck = null;
    _intentRevision++;
    _settlePlayingWaiters(const CommandResult.superseded());
    _publish();
    if (_phase == PlaybackPhase.ready) unawaited(_ensureWriter());
    return token;
  }

  Future<CommandResult> releaseSessionInhibitor(
    PlaybackInhibitorToken token,
  ) {
    if (_closingRequested || _disposed) {
      return Future.value(const CommandResult.closed());
    }
    if (!_sessionInhibitors.remove(token)) {
      return Future.value(const CommandResult.superseded());
    }
    _updateRecoveryClock();
    _intentRevision++;
    _settlePlayingWaiters(const CommandResult.superseded());
    _publish();
    if (_phase != PlaybackPhase.ready) {
      return Future.value(const CommandResult.applied());
    }
    return _ensureWriter().then((result) {
      if (result.outcome == CommandOutcome.applied) {
        _resumeDeferredRecovery();
      }
      return result;
    });
  }

  bool isCurrent(int requestId) =>
      !_closingRequested && !_disposed && requestId == _requestId;

  Future<void> get shutdownDone =>
      _shutdownTask?.then<void>((_) {}) ?? Future<void>.value();

  Future<PlaybackShutdownResult> shutdown() {
    if (!_shutdownStarted && !_disposed) _requestShutdown();
    return _shutdownTask ??
        Future<PlaybackShutdownResult>.value(
          const PlaybackShutdownResult.released(),
        );
  }

  Future<LoadResult> _load(
    PlaybackOwner owner,
    PlaybackPlan plan, {
    required PlaybackStartPolicy start,
    bool automaticRecovery = false,
    bool retainRequestId = false,
    bool preservePendingConfiguration = false,
  }) {
    final rejected = _rejectLoad(owner);
    if (rejected != null) return Future.value(rejected);

    // Same-content source refreshes may be resolved from an older facade
    // snapshot. Preserve the session's latest user-selected configuration.
    final acceptedPlan = _currentPlan?.contentKey == plan.contentKey
        ? plan.withConfiguration(_desiredConfiguration)
        : plan;

    var requestBudget = loadBudget;
    if (automaticRecovery && !_consumeRecoveryBudget(acceptedPlan.contentKey)) {
      final failure = PlaybackFailure(
        category: PlaybackFailureCategory.network,
        operation: 'automatic-recovery',
        stage: _stage,
        recoverable: false,
        cause: '自动恢复预算已耗尽。',
      );
      _publishFailure(failure);
      return Future.value(LoadResult.failed(failure));
    } else if (automaticRecovery) {
      final recoveryRemaining = _recoveryRemaining();
      if (recoveryRemaining <= Duration.zero) {
        final failure = _recoveryBudgetFailure();
        _publishFailure(failure);
        return Future.value(LoadResult.failed(failure));
      }
      if (recoveryRemaining < requestBudget) requestBudget = recoveryRemaining;
    }
    if (!automaticRecovery &&
        _currentPlan?.contentKey != acceptedPlan.contentKey) {
      _recoveryIncident = null;
      _healthySince = null;
      _healthyCheck?.cancel();
    }

    final request = _acceptRequest(
      owner,
      start,
      automaticRecovery ? PlaybackStage.recovering : PlaybackStage.queued,
      budget: requestBudget,
      retainRequestId: retainRequestId,
    );
    if (request == null) {
      return Future.value(_closedOrInactive(owner));
    }
    _desiredConfiguration = acceptedPlan.configuration;
    if (!preservePendingConfiguration) _configurationPending.clear();
    request
      ..recovery = automaticRecovery
      ..finalPlan = acceptedPlan;
    _publish();
    _scheduleLoad(request, acceptedPlan);
    return request.result.future;
  }

  Future<LoadResult> _query(
    PlaybackOwner owner,
    Future<PlaybackPlan?> Function(PlaybackQuery query) resolve, {
    required PlaybackStartPolicy start,
    bool Function()? shouldLoad,
  }) {
    final rejected = _rejectLoad(owner);
    if (rejected != null) return Future.value(rejected);
    final request = _acceptRequest(owner, start, PlaybackStage.resolving);
    if (request == null) {
      return Future.value(_closedOrInactive(owner));
    }
    request.shouldLoad = shouldLoad;
    _publish();
    final ownerGeneration = owner._generation;
    final query = PlaybackQuery(
      requestId: request.id,
      isCurrent: () =>
          owner._generation == ownerGeneration &&
          (_isRequestCurrent(request) ||
              request.loaded &&
                  _isCommandCurrent(owner, request.id, request.loadId!) ||
              request.resolved && isCurrent(request.id) && owner.isActive),
      registerCancel: (cancel) {
        if (_isRequestCurrent(request)) {
          request.cancelCallbacks.add(cancel);
        } else {
          cancel();
        }
      },
    );
    unawaited(_resolveQuery(request, query, resolve));
    return request.result.future;
  }

  Future<void> _resolveQuery(
    _AcceptedRequest request,
    PlaybackQuery query,
    Future<PlaybackPlan?> Function(PlaybackQuery query) resolve,
  ) async {
    final remaining = request.deadline - _now();
    if (remaining <= Duration.zero) {
      _expireRequest(request);
      return;
    }
    try {
      final plan = await resolve(query).timeout(remaining);
      if (!_isRequestCurrent(request)) return;
      if (plan == null) {
        _finishRequest(
          request,
          const LoadResult.failed(
            PlaybackFailure(
              category: PlaybackFailureCategory.source,
              operation: 'query',
              stage: PlaybackStage.resolving,
              recoverable: false,
              cause: '来源解析没有返回播放计划。',
            ),
          ),
        );
        _phase = PlaybackPhase.failed;
        _stage = PlaybackStage.idle;
        _publish();
        return;
      }
      if (!_isRequestCurrent(request)) return;
      if (request.shouldLoad?.call() == false) {
        request.resolved = true;
        request.owner._requiresLoad = true;
        _phase = PlaybackPhase.idle;
        _stage = PlaybackStage.idle;
        _failure = null;
        _finishRequest(request, const LoadResult.noMedia());
        _publish();
        return;
      }
      _stage = PlaybackStage.queued;
      _publish();
      _scheduleLoad(request, plan);
    } on TimeoutException {
      _expireRequest(request);
    } catch (error) {
      if (!_isRequestCurrent(request)) return;
      final failure = PlaybackFailure(
        category: PlaybackFailureCategory.source,
        operation: 'query',
        stage: PlaybackStage.resolving,
        recoverable: false,
        cause: error.toString(),
      );
      _finishRequest(request, LoadResult.failed(failure));
      _phase = PlaybackPhase.failed;
      _stage = PlaybackStage.idle;
      _failure = failure;
      _publish();
    }
  }

  _AcceptedRequest? _acceptRequest(
    PlaybackOwner owner,
    PlaybackStartPolicy start,
    PlaybackStage stage, {
    Duration? budget,
    bool retainRequestId = false,
  }) {
    if (_closingRequested || _disposed || owner._closed) return null;
    if (!owner.isActive) return null;
    _invalidateMediaAnchor();
    _supersedeAcceptedRequest();
    _operations.prioritizeLoad();
    final acceptedAt = _now();
    final requestBudget = budget ?? loadBudget;
    final request = _AcceptedRequest(
      id: retainRequestId ? _requestId : ++_requestId,
      owner: owner,
      deadline: acceptedAt + requestBudget,
      configurationRevisionsAtAcceptance: Map.of(_configurationRevisions),
    );
    _acceptedRequest = request;
    if (start == PlaybackStartPolicy.play) owner._playing = true;
    if (start == PlaybackStartPolicy.pause) owner._playing = false;
    _updateRecoveryClock(acceptedAt);
    _intentRevision++;
    _writerLoadRequestId = null;
    _phase = _phaseForStage(stage);
    _stage = stage;
    _failure = null;
    _pendingAction = null;
    request.timer = Timer(requestBudget, () => _expireRequest(request));
    _settlePlayingWaiters(const CommandResult.superseded());
    _emitTrace('request.accepted', {
      'requestId': request.id,
      'stage': stage.name,
    });
    // 地址解析也属于加载阶段；先暂停旧媒体，避免加载态下声音继续推进。
    unawaited(_scheduleWriterIfReady());
    return request;
  }

  PlaybackPhase _phaseForStage(PlaybackStage stage) =>
      stage == PlaybackStage.recovering
      ? PlaybackPhase.recovering
      : PlaybackPhase.loading;

  void _scheduleLoad(_AcceptedRequest request, PlaybackPlan plan) {
    if (!_isRequestCurrent(request)) return;
    final effectivePlan = _mergeConfigChangesSinceAcceptance(request, plan);
    _stage = PlaybackStage.queued;
    _publish();
    final task = _operations.submit<PlaybackRuntimeLoadResult>(
      slot: request.recovery
          ? PlaybackOperationSlot.recovery
          : PlaybackOperationSlot.load,
      deadline: request.deadline,
      cancel: () => _cancelRequestCallbacks(request),
      operation: (operation) async {
        if (!_isRequestCurrent(request) || !operation.isCurrent()) {
          throw const _PlaybackSuperseded();
        }
        await _waitForWriter(request.deadline);
        if (!_isRequestCurrent(request) || !operation.isCurrent()) {
          throw const _PlaybackSuperseded();
        }
        return _executeLoad(request, effectivePlan, operation);
      },
    );
    unawaited(_completeScheduledLoad(request, task));
  }

  Future<void> _completeScheduledLoad(
    _AcceptedRequest request,
    Future<PlaybackOperationResult<PlaybackRuntimeLoadResult>> task,
  ) async {
    final result = await task;
    if (!_isRequestCurrent(request)) return;
    switch (result.outcome) {
      case PlaybackOperationOutcome.completed:
        final value = result.value;
        if (value == null || !value.loaded) {
          final failure =
              value?.failure ??
              PlaybackFailure(
                category: PlaybackFailureCategory.source,
                operation: 'load',
                stage: _stage,
                recoverable: false,
                cause: '运行时没有确认当前媒体已加载。',
              );
          _failLoad(request, failure);
          return;
        }
        if (value.output.strategy == PlaybackOutputStrategy.unknown ||
            value.output.strategy == PlaybackOutputStrategy.failed) {
          _failLoad(
            request,
            PlaybackFailure(
              category: PlaybackFailureCategory.output,
              operation: 'prepare-output',
              stage: PlaybackStage.outputPreparing,
              recoverable: false,
              cause: value.output.evidence,
            ),
          );
          return;
        }
        _currentPlan = _planForCurrentConfig(request, value);
        request.owner._requiresLoad = false;
        _appliedConfiguration = _currentPlan!.configuration;
        _desiredConfiguration = _currentPlan!.configuration;
        _configurationPending.clear();
        _presentation = PlaybackPresentation(
          outputStrategy: value.output.strategy,
          evidence: value.output.evidence,
          outputEpoch: value.output.outputEpoch,
          width: value.output.width,
          height: value.output.height,
        );
        _capabilities =
            value.capabilities ??
            PlaybackCapabilities(
              seekSupport:
                  _currentPlan!.timeline.seekPolicy ==
                      PlaybackSeekPolicy.disabled
                  ? PlaybackSeekSupport.unsupported
                  : PlaybackSeekSupport.unknown,
              hasVideo: value.output.hasVideo,
            );
        _stage = PlaybackStage.reconcilingIntent;
        _writerLoadRequestId = request.id;
        _publish();
        final playResult = await _ensureWriter();
        _writerLoadRequestId = null;
        if (!_isRequestCurrent(request)) return;
        if (playResult.outcome != CommandOutcome.applied) {
          _failLoad(
            request,
            playResult.failure ??
                const PlaybackFailure(
                  category: PlaybackFailureCategory.unknown,
                  operation: 'reconcile-playback-intent',
                  stage: PlaybackStage.reconcilingIntent,
                  recoverable: false,
                  cause: '加载后协调播放意图失败。',
                ),
          );
          return;
        }
        _phase = PlaybackPhase.ready;
        if (_runtime case final PlaybackMediaClockSampler sampler) {
          sampler.sampleMediaClock();
        }
        _stage = PlaybackStage.observing;
        _failure = null;
        _observeHealth(_now());
        _emitTrace('load.ready', {
          'requestId': request.id,
          'loadId': request.loadId,
          'output': value.output.strategy.name,
        });
        _finishRequest(request, LoadResult.ready(request.loadId!));
        _publish();
        _resumeDeferredRecovery();
      case PlaybackOperationOutcome.superseded:
        _finishRequest(request, const LoadResult.superseded());
      case PlaybackOperationOutcome.timedOut:
        _failLoad(
          request,
          PlaybackFailure(
            category: PlaybackFailureCategory.timeout,
            operation: 'load',
            stage: _stage,
            recoverable: true,
            cause: '加载超过接受时的总时限。',
          ),
        );
      case PlaybackOperationOutcome.closed:
        _finishRequest(request, const LoadResult.closed());
      case PlaybackOperationOutcome.failed:
        final error = result.error;
        if (error is _PlaybackSuperseded) {
          _finishRequest(request, const LoadResult.superseded());
          return;
        }
        _failLoad(
          request,
          PlaybackFailure(
            category: error is TimeoutException
                ? PlaybackFailureCategory.timeout
                : PlaybackFailureCategory.unknown,
            operation: 'load',
            stage: _stage,
            recoverable: false,
            cause: error.toString(),
          ),
        );
    }
  }

  Future<PlaybackRuntimeLoadResult> _executeLoad(
    _AcceptedRequest request,
    PlaybackPlan initialPlan,
    PlaybackOperationContext operation,
  ) async {
    var plan = initialPlan;
    if (identical(_lastLoadOwner, request.owner) &&
        _lastLoadPlan?.contentKey == plan.contentKey) {
      plan = _planForReload(plan);
    }
    while (true) {
      if (!_isRequestCurrent(request) || !operation.isCurrent()) {
        throw const _PlaybackSuperseded();
      }
      if (request.deadline <= _now()) throw TimeoutException('load deadline');
      final thisLoadId = ++_loadId;
      request.loadId = thisLoadId;
      _stage = PlaybackStage.initializing;
      _publish();
      final context = PlaybackExecutionContext(
        requestId: request.id,
        runtimeId: _runtime.runtimeId,
        loadId: thisLoadId,
        seekSequence: _seekSequence,
        deadline: request.deadline,
        monotonicNow: _now,
        cancelled: request.cancelled.future,
        registerCancellation: request.registerCancel,
        isCurrent: () =>
            _isRequestCurrent(request) &&
            request.loadId == thisLoadId &&
            operation.isCurrent(),
      );
      _stage = PlaybackStage.opening;
      _publish();
      // stop/open 会清零原生位置；失败与取消后的下一次重试沿用这份续播点。
      _lastLoadPlan = plan;
      _lastLoadOwner = request.owner;
      _runtimePositionAvailable = false;
      final result = await _runtime.load(plan, context);
      request.finalPlan = plan;
      if (!context.isCurrent()) throw const _PlaybackSuperseded();
      _stage = PlaybackStage.outputPreparing;
      _publish();
      if (!result.loaded ||
          result.output.strategy == PlaybackOutputStrategy.unknown ||
          result.output.strategy == PlaybackOutputStrategy.failed) {
        return result;
      }
      final desired = _configurationDuringLoad(request, plan.configuration);
      if (!_sameConfiguration(desired, plan.configuration)) {
        plan = plan.withConfiguration(desired);
        // 配置在本次加载期间变化时，以相同结构协议重新加载最新完整计划。
        continue;
      }
      // 直播预期包含画面；已确认无视频轨时直接轮换候选，避免等待纯音频流 EOF。
      if (plan.timeline.kind == PlaybackTimelineKind.live &&
          !plan.configuration.audioOnly &&
          result.output.strategy == PlaybackOutputStrategy.noVideo) {
        final next = plan.source.advanceCandidate();
        if (next != null) {
          _emitTrace('load.missing-video', {
            'loadId': thisLoadId,
            'candidate': plan.source.candidateIndex,
          });
          plan = plan.withSource(next);
          continue;
        }
        return PlaybackRuntimeLoadResult(
          loaded: false,
          output: result.output,
          failure: const PlaybackFailure(
            category: PlaybackFailureCategory.source,
            operation: 'validate-live-video',
            stage: PlaybackStage.outputPreparing,
            recoverable: false,
            cause: '直播候选均未提供视频轨。',
          ),
        );
      }
      if (!context.isCurrent()) throw const _PlaybackSuperseded();
      _runtimePositionAvailable = true;
      return result;
    }
  }

  PlaybackPlan _planForCurrentConfig(
    _AcceptedRequest request,
    PlaybackRuntimeLoadResult result,
  ) {
    final plan = request.finalPlan;
    if (plan == null) {
      throw StateError('Runtime load completed without a plan.');
    }
    return plan;
  }

  PlaybackPlan _mergeConfigChangesSinceAcceptance(
    _AcceptedRequest request,
    PlaybackPlan plan,
  ) {
    final config = _configurationDuringLoad(request, plan.configuration);
    final merged = plan.withConfiguration(config);
    request.finalPlan = merged;
    _desiredConfiguration = config;
    return merged;
  }

  PlaybackConfiguration _configurationDuringLoad(
    _AcceptedRequest request,
    PlaybackConfiguration base,
  ) {
    var result = base;
    bool changed(PlaybackConfigurationKey key) =>
        (_configurationRevisions[key] ?? 0) >
        (request.configurationRevisionsAtAcceptance[key] ?? 0);
    final desired = _desiredConfiguration;
    if (changed(PlaybackConfigurationKey.audioOnly)) {
      result = result.copyWith(audioOnly: desired.audioOnly);
    }
    if (changed(PlaybackConfigurationKey.playbackSpeed)) {
      result = result.copyWith(playbackSpeed: desired.playbackSpeed);
    }
    if (changed(PlaybackConfigurationKey.volume)) {
      result = result.copyWith(volume: desired.volume);
    }
    if (changed(PlaybackConfigurationKey.decoder)) {
      result = result.copyWith(hwdec: desired.hwdec);
    }
    if (changed(PlaybackConfigurationKey.audioTrack)) {
      result = result.copyWith(
        audioTrackId: desired.audioTrackId,
        clearAudioTrack: desired.audioTrackId == null,
      );
    }
    if (changed(PlaybackConfigurationKey.videoTrack)) {
      result = result.copyWith(
        videoTrackId: desired.videoTrackId,
        clearVideoTrack: desired.videoTrackId == null,
      );
    }
    if (changed(PlaybackConfigurationKey.subtitleTrack)) {
      result = result.copyWith(
        subtitleTrack: desired.subtitleTrack,
        clearSubtitleTrack: desired.subtitleTrack == null,
      );
    }
    if (changed(PlaybackConfigurationKey.shaders)) {
      result = result.copyWith(shaders: desired.shaders);
    }
    if (changed(PlaybackConfigurationKey.mediaOptions)) {
      result = result.copyWith(mediaOptions: desired.mediaOptions);
    }
    return result;
  }

  Future<CommandResult> _setPlaying(PlaybackOwner owner, bool playing) {
    final rejection = _rejectCommand(owner);
    if (rejection != null) return Future.value(rejection);
    if ((_currentPlan == null && _acceptedRequest == null) ||
        (owner._requiresLoad && !identical(_acceptedRequest?.owner, owner))) {
      return Future.value(const CommandResult.noMedia());
    }
    final previous = owner._playing;
    owner._playing = playing;
    if (!playing) {
      _healthySince = null;
      _healthyCheck?.cancel();
      _healthyCheck = null;
    }
    _updateRecoveryClock();
    final revision = ++_intentRevision;
    _settlePlayingWaiters(const CommandResult.superseded());
    _publish();
    if (_phase != PlaybackPhase.ready) {
      return Future.value(const CommandResult.accepted());
    }
    if (previous == playing && _effectivePlaying == _actual.playing) {
      if (playing) _resumeDeferredRecovery();
      return Future.value(const CommandResult.applied());
    }
    final completer = Completer<CommandResult>();
    _playingWaiters[revision] = completer;
    // 调用方按接受意图时的预算结算；writer 继续排空原生调用并落实最新意图。
    final timer = Timer(commandBudget, () {
      _settlePlayingRevision(
        revision,
        CommandResult.failed(
          PlaybackFailure(
            category: PlaybackFailureCategory.timeout,
            operation: playing ? 'play' : 'pause',
            stage: _stage,
            recoverable: false,
            cause: '播放状态写入超过命令预算。',
          ),
        ),
      );
    });
    _ensureWriter();
    unawaited(
      completer.future.then((result) {
        timer.cancel();
        if (playing && result.outcome == CommandOutcome.applied) {
          _resumeDeferredRecovery();
        }
      }),
    );
    return completer.future;
  }

  bool get _effectivePlaying {
    if (_phase != PlaybackPhase.ready &&
        !((_phase == PlaybackPhase.loading ||
                _phase == PlaybackPhase.recovering) &&
            _writerLoadRequestId == _requestId)) {
      return false;
    }
    final owner = _activeOwner;
    if (owner == null ||
        owner._requiresLoad ||
        !owner._playing ||
        _sessionInhibitors.isNotEmpty) {
      return false;
    }
    return (_ownerInhibitors[owner]?.isEmpty ?? true);
  }

  Future<void> _scheduleWriterIfReady() {
    if (_writerPermitted) return _ensureWriter();
    return Future<void>.value();
  }

  Future<CommandResult> _ensureWriter() {
    if (!_writerRunning) unawaited(_runPlaybackWriter());
    final revision = _intentRevision;
    final existing = _playingWaiters[revision];
    if (existing != null) return existing.future;
    if ((_phase == PlaybackPhase.loading ||
            _phase == PlaybackPhase.recovering) &&
        _writerLoadRequestId == _requestId) {
      // Load settlement has its own caller; use a temporary completion waiter.
      final completer = Completer<CommandResult>();
      _playingWaiters[revision] = completer;
      return completer.future;
    }
    if (_phase != PlaybackPhase.ready) {
      return Future.value(const CommandResult.accepted());
    }
    final completer = Completer<CommandResult>();
    _playingWaiters[revision] = completer;
    return completer.future;
  }

  Future<void> _runPlaybackWriter() async {
    if (_writerRunning || !_writerPermitted) return;
    _writerRunning = true;
    final drain = Completer<void>();
    _writerDrain = drain;
    try {
      while (_writerPermitted && !_closingRequested) {
        final revision = _intentRevision;
        final owner = _activeOwner;
        final target = _effectivePlaying;
        final context = PlaybackExecutionContext(
          requestId: _requestId,
          runtimeId: _runtime.runtimeId,
          loadId: _loadId,
          deadline: _now() + commandBudget,
          monotonicNow: _now,
          cancelled: Future<void>.value(),
          registerCancellation: (_) {},
          isCurrent: () =>
              !_closingRequested &&
              revision == _intentRevision &&
              // 最后一个页面退出时仍需向原生提交暂停，归属为空也是有效状态。
              identical(owner, _activeOwner) &&
              _writerPermitted,
        );
        final result = await _runtime.setPlaying(target, context);
        if (!_closingRequested && context.isCurrent()) {
          if (result.failure != null || !result.applied) {
            final failure =
                result.failure ??
                PlaybackFailure(
                  category: PlaybackFailureCategory.unknown,
                  operation: target ? 'play' : 'pause',
                  stage: _stage,
                  recoverable: false,
                  cause: '原生没有确认播放状态写入。',
                );
            _settlePlayingRevision(
              revision,
              CommandResult.failed(failure),
            );
          } else {
            _actual = PlaybackActual(
              playing: _actual.playing,
              buffering: _actual.buffering,
              seeking: _actual.seeking,
              position: _actual.position,
              duration: _actual.duration,
              audioProgressing: _actual.audioProgressing,
              videoProgressing: _actual.videoProgressing,
            );
            _settlePlayingRevision(revision, const CommandResult.applied());
          }
          _publish();
        } else {
          _settlePlayingRevision(revision, const CommandResult.superseded());
        }
        if (revision == _intentRevision) break;
      }
    } catch (error) {
      final revision = _intentRevision;
      _settlePlayingRevision(
        revision,
        CommandResult.failed(
          PlaybackFailure(
            category: PlaybackFailureCategory.unknown,
            operation: 'playback-intent',
            stage: _stage,
            recoverable: false,
            cause: error.toString(),
          ),
        ),
      );
    } finally {
      _writerRunning = false;
      _writerDrain = null;
      if (!drain.isCompleted) drain.complete();
      if (_writerPermitted &&
          !_closingRequested &&
          _playingWaiters.containsKey(_intentRevision)) {
        unawaited(_runPlaybackWriter());
      }
    }
  }

  bool get _writerPermitted =>
      _phase == PlaybackPhase.ready ||
      (_runtimePositionAvailable &&
          (_phase == PlaybackPhase.loading ||
              _phase == PlaybackPhase.recovering ||
              _phase == PlaybackPhase.failed)) ||
      ((_phase == PlaybackPhase.loading ||
              _phase == PlaybackPhase.recovering) &&
          _writerLoadRequestId != null &&
          _writerLoadRequestId == _requestId);

  Future<void> _waitForWriter(Duration deadline) async {
    final drain = _writerDrain;
    if (drain == null) return;
    final remaining = deadline - _now();
    if (remaining <= Duration.zero) throw TimeoutException('playback writer');
    await drain.future.timeout(remaining);
  }

  void _settlePlayingRevision(int revision, CommandResult result) {
    final completer = _playingWaiters.remove(revision);
    if (completer != null && !completer.isCompleted) completer.complete(result);
  }

  void _settlePlayingWaiters(CommandResult result) {
    for (final completer in _playingWaiters.values) {
      if (!completer.isCompleted) completer.complete(result);
    }
    _playingWaiters.clear();
  }

  Future<CommandResult> _seek(PlaybackOwner owner, Duration target) async {
    final rejection = _rejectCommand(owner);
    if (rejection != null) return rejection;
    if (_currentPlan == null && !identical(_acceptedRequest?.owner, owner)) {
      return const CommandResult.noMedia();
    }
    if (owner._requiresLoad) {
      return _phase == PlaybackPhase.loading ||
              _phase == PlaybackPhase.recovering
          ? const CommandResult.notReady()
          : const CommandResult.noMedia();
    }
    if (_phase == PlaybackPhase.loading || _phase == PlaybackPhase.recovering) {
      return const CommandResult.notReady();
    }
    if (_phase != PlaybackPhase.ready) return const CommandResult.notReady();
    if (_capabilities.seekSupport == PlaybackSeekSupport.unknown) {
      return const CommandResult.capabilityPending();
    }
    if (_capabilities.seekSupport == PlaybackSeekSupport.unsupported) {
      return const CommandResult.unsupported();
    }
    final start = _capabilities.seekStart;
    final end = _capabilities.seekEnd;
    if ((start != null && target < start) || (end != null && target > end)) {
      return const CommandResult.outOfRange();
    }
    final request = _requestId;
    final load = _loadId;
    final seekSequence = ++_seekSequence;
    _invalidateMediaAnchor();
    _pendingSeekSequence = seekSequence;
    final deadline = _now() + commandBudget;
    try {
      if (_runtime case final PlaybackSeekSubmissionGate gate) {
        final cancelled = Completer<void>();
        _seekWaitCancelled = cancelled;
        final ready = Completer<void>();
        void checkReady() {
          if (!gate.seekSubmissionBlocked && !ready.isCompleted) {
            ready.complete();
          }
        }

        final subscription = gate.seekSubmissionChanges.listen(
          (_) => checkReady(),
        );
        checkReady();
        try {
          await Future.any([ready.future, cancelled.future])
              .timeout(commandBudget);
        } on TimeoutException {
          return _commandResult(
            const PlaybackOperationResult<
              PlaybackRuntimeCommandResult
            >.timedOut(),
            'seek',
            PlaybackStage.observing,
          );
        } finally {
          await subscription.cancel();
          if (identical(_seekWaitCancelled, cancelled)) {
            _seekWaitCancelled = null;
          }
        }
        if (cancelled.isCompleted ||
            !_isCommandCurrent(owner, request, load) ||
            seekSequence != _seekSequence) {
          return const CommandResult.superseded();
        }
      }
      final result = await _operations.submit<PlaybackRuntimeCommandResult>(
        slot: PlaybackOperationSlot.seek,
        deadline: deadline,
        operation: (operation) {
          if (!_isCommandCurrent(owner, request, load) ||
              seekSequence != _seekSequence ||
              !operation.isCurrent()) {
            throw const _PlaybackSuperseded();
          }
          if (_capabilities.seekSupport != PlaybackSeekSupport.supported) {
            throw const _PlaybackUnsupported();
          }
          return _runtime.seek(
            target,
            PlaybackExecutionContext(
              requestId: request,
              runtimeId: _runtime.runtimeId,
              loadId: load,
              seekSequence: seekSequence,
              deadline: operation.deadline,
              monotonicNow: _now,
              cancelled: Future<void>.value(),
              registerCancellation: (_) {},
              isCurrent: () =>
                  _isCommandCurrent(owner, request, load) &&
                  seekSequence == _seekSequence &&
                  operation.isCurrent(),
            ),
          );
        },
      );
      return _commandResult(result, 'seek', PlaybackStage.observing);
    } finally {
      if (_pendingSeekSequence == seekSequence) {
        _pendingSeekSequence = null;
        _resumeDeferredRecovery();
      }
    }
  }

  Future<CommandResult> _setConfiguration(
    PlaybackOwner owner,
    PlaybackConfigurationKey key,
    PlaybackOperationSlot slot,
    PlaybackConfiguration Function(PlaybackConfiguration current) update, {
    Set<PlaybackConfigurationKey> alsoChanged = const {},
  }) {
    final rejection = _rejectCommand(owner);
    if (rejection != null) return Future.value(rejection);
    if (_currentPlan == null && _acceptedRequest == null) {
      return Future.value(const CommandResult.noMedia());
    }
    final current = _desiredConfiguration;
    final desired = update(current);
    if (_sameConfiguration(current, desired)) {
      return Future.value(const CommandResult.applied());
    }
    _desiredConfiguration = desired;
    final changedKeys = <PlaybackConfigurationKey>{key, ...alsoChanged};
    final revisions = <PlaybackConfigurationKey, int>{};
    for (final changedKey in changedKeys) {
      final revision = (_configurationRevisions[changedKey] ?? 0) + 1;
      _configurationRevisions[changedKey] = revision;
      _configurationPending.add(changedKey);
      revisions[changedKey] = revision;
    }
    _publish();
    if (_phase != PlaybackPhase.ready) {
      return Future.value(const CommandResult.accepted());
    }
    if (owner._requiresLoad && !identical(_acceptedRequest?.owner, owner)) {
      return Future.value(const CommandResult.accepted());
    }
    if (_requiresConfigurationReload(key)) {
      return _reloadForConfiguration(owner);
    }
    final request = _requestId;
    final load = _loadId;
    final deadline = _now() + commandBudget;
    final operation = _operations.submit<PlaybackRuntimeCommandResult>(
      slot: slot,
      deadline: deadline,
      operation: (context) async {
        if (!_isCommandCurrent(owner, request, load) || !context.isCurrent()) {
          throw const _PlaybackSuperseded();
        }
        final target = key == PlaybackConfigurationKey.playbackSpeed
            ? (
                speed: _desiredConfiguration.playbackSpeed,
                mediaOptions: _desiredConfiguration.mediaOptions,
              )
            : _configurationValue(key, _desiredConfiguration);
        final commandContext = PlaybackExecutionContext(
          requestId: request,
          runtimeId: _runtime.runtimeId,
          loadId: load,
          deadline: context.deadline,
          monotonicNow: _now,
          cancelled: Future<void>.value(),
          registerCancellation: (_) {},
          isCurrent: () =>
              _isCommandCurrent(owner, request, load) &&
              revisions.entries.every(
                (entry) => _configurationRevisions[entry.key] == entry.value,
              ) &&
              context.isCurrent(),
        );
        final result = await _runConfigurationCommand(
          key,
          target,
          commandContext,
        );
        if (commandContext.isCurrent() &&
            result.failure == null &&
            result.applied) {
          for (final changedKey in changedKeys) {
            _appliedConfiguration = _copyConfigurationKey(
              _appliedConfiguration,
              _desiredConfiguration,
              changedKey,
            );
            if (_configurationRevisions[changedKey] == revisions[changedKey]) {
              _configurationPending.remove(changedKey);
            }
          }
          if (_currentPlan case final plan?) {
            _currentPlan = plan.withConfiguration(_desiredConfiguration);
          }
          _publish();
        }
        return result;
      },
    );
    return operation.then((result) {
      if (revisions.entries.every(
        (entry) => _configurationRevisions[entry.key] == entry.value,
      )) {
        if (result.outcome != PlaybackOperationOutcome.completed) {
          _configurationPending.removeAll(changedKeys);
          _publish();
        }
      }
      return _commandResult(result, key.name, PlaybackStage.observing);
    });
  }

  Future<PlaybackRuntimeCommandResult> _runConfigurationCommand(
    PlaybackConfigurationKey key,
    Object? target,
    PlaybackExecutionContext context,
  ) => switch (key) {
    PlaybackConfigurationKey.audioOnly => _runtime.setAudioOnly(
      target! as bool,
      context,
    ),
    PlaybackConfigurationKey.playbackSpeed => _runtime.setPlaybackSpeed(
      (target! as ({double speed, Map<String, String> mediaOptions})).speed,
      (target as ({double speed, Map<String, String> mediaOptions}))
          .mediaOptions,
      context,
    ),
    PlaybackConfigurationKey.volume => _runtime.setVolume(
      target! as double,
      context,
    ),
    PlaybackConfigurationKey.decoder => _runtime.setDecoder(
      PlaybackDecoder(target! as String, kind: PlaybackDecoderKind.custom),
      context,
    ),
    PlaybackConfigurationKey.audioTrack => _runtime.setAudioTrack(
      target as int?,
      context,
    ),
    PlaybackConfigurationKey.subtitleTrack => _runtime.setSubtitleTrack(
      target as PlaybackSubtitleTrack?,
      context,
    ),
    PlaybackConfigurationKey.shaders => _runtime.setShader(
      target! as List<String>,
      context,
    ),
    PlaybackConfigurationKey.videoTrack ||
    PlaybackConfigurationKey.mediaOptions => Future.value(
      PlaybackRuntimeCommandResult(
        applied: false,
        failure: PlaybackFailure(
          category: PlaybackFailureCategory.capability,
          operation: key.name,
          stage: PlaybackStage.observing,
          recoverable: false,
          cause: '该配置仅可在下一份完整播放计划中应用。',
        ),
      ),
    ),
  };

  bool _requiresConfigurationReload(PlaybackConfigurationKey key) {
    final plan = _currentPlan;
    if (plan?.timeline.kind != PlaybackTimelineKind.live ||
        _capabilities.seekSupport == PlaybackSeekSupport.supported) {
      return false;
    }
    return switch (key) {
      PlaybackConfigurationKey.decoder ||
      PlaybackConfigurationKey.audioOnly => true,
      PlaybackConfigurationKey.shaders =>
        _runtime.shaderChangeRequiresRendererReset,
      _ => false,
    };
  }

  Future<CommandResult> _reloadForConfiguration(PlaybackOwner owner) async {
    final plan = _currentPlan;
    if (plan == null) return const CommandResult.noMedia();
    final reloadPlan = _planForReload(plan);
    final result = await _load(
      owner,
      reloadPlan,
      start: PlaybackStartPolicy.preserve,
      retainRequestId: true,
      preservePendingConfiguration: true,
    );
    return switch (result.outcome) {
      LoadOutcome.ready => const CommandResult.applied(),
      LoadOutcome.noMedia => const CommandResult.noMedia(),
      LoadOutcome.deferred => const CommandResult.accepted(),
      LoadOutcome.superseded => const CommandResult.superseded(),
      LoadOutcome.inactive => const CommandResult.inactive(),
      LoadOutcome.closed => const CommandResult.closed(),
      LoadOutcome.failed =>
        result.failure == null
            ? CommandResult.failed(
                PlaybackFailure(
                  category: PlaybackFailureCategory.unknown,
                  operation: 'configuration-reload',
                  stage: _stage,
                  recoverable: false,
                  cause: '配置重载失败，但运行时未提供失败详情。',
                ),
              )
            : CommandResult.failed(result.failure!),
    };
  }

  Object? _configurationValue(
    PlaybackConfigurationKey key,
    PlaybackConfiguration config,
  ) => switch (key) {
    PlaybackConfigurationKey.audioOnly => config.audioOnly,
    PlaybackConfigurationKey.playbackSpeed => config.playbackSpeed,
    PlaybackConfigurationKey.volume => config.volume,
    PlaybackConfigurationKey.decoder => config.hwdec,
    PlaybackConfigurationKey.audioTrack => config.audioTrackId,
    PlaybackConfigurationKey.videoTrack => config.videoTrackId,
    PlaybackConfigurationKey.subtitleTrack => config.subtitleTrack,
    PlaybackConfigurationKey.shaders => config.shaders,
    PlaybackConfigurationKey.mediaOptions => config.mediaOptions,
  };

  PlaybackInhibitorToken? _acquireInhibitor(
    PlaybackOwner owner,
    PlaybackInhibitorSource source,
  ) {
    if (owner._closed || _closingRequested || !owner._attached) return null;
    final token = PlaybackInhibitorToken(
      source: source,
      id: _nextInhibitorId++,
    );
    owner._inhibitors.add(token);
    _ownerInhibitors
        .putIfAbsent(owner, () => <PlaybackInhibitorToken>{})
        .add(token);
    _updateRecoveryClock();
    if (identical(_activeOwner, owner)) {
      _intentRevision++;
      _settlePlayingWaiters(const CommandResult.superseded());
      _publish();
      if (_phase == PlaybackPhase.ready) unawaited(_ensureWriter());
    }
    _publish();
    return token;
  }

  Future<CommandResult> _releaseInhibitor(
    PlaybackOwner owner,
    PlaybackInhibitorToken token,
  ) {
    if (owner._closed || _closingRequested) {
      return Future.value(const CommandResult.closed());
    }
    if (!owner._inhibitors.remove(token)) {
      return Future.value(const CommandResult.superseded());
    }
    _ownerInhibitors[owner]?.remove(token);
    _updateRecoveryClock();
    if (identical(_activeOwner, owner)) {
      _intentRevision++;
      _settlePlayingWaiters(const CommandResult.superseded());
      _publish();
      if (_phase == PlaybackPhase.ready) {
        return _ensureWriter().then((result) {
          if (result.outcome == CommandOutcome.applied) {
            _resumeDeferredRecovery();
          }
          return result;
        });
      }
    }
    _publish();
    return Future.value(const CommandResult.applied());
  }

  PlaybackPlan _planForReload(PlaybackPlan plan) {
    // 状态快照按状态变化发布，续播位置在真正提交重载时向运行时采样。
    final sameMedia = _lastLoadPlan?.contentKey == plan.contentKey;
    final position = plan.timeline.kind == PlaybackTimelineKind.live
        ? null
        : (sameMedia && _runtimePositionAvailable
                  ? _runtime.position ?? _actual.position
                  : null) ??
              (sameMedia
                  ? _lastLoadPlan?.reloadPosition ??
                        _lastLoadPlan?.startPosition
                  : null) ??
              plan.reloadPosition ??
              plan.startPosition;
    return PlaybackPlan(
      contentKey: plan.contentKey,
      source: plan.source,
      timeline: plan.timeline,
      configuration: _desiredConfiguration,
      startPosition: position,
      reloadPosition: position,
      metadata: plan.metadata,
    );
  }

  Future<CommandResult> _reloadAudio(PlaybackOwner owner) async {
    final rejection = _rejectCommand(owner);
    if (rejection != null) return rejection;
    if (_currentPlan == null) return const CommandResult.noMedia();
    if (owner._requiresLoad || _phase != PlaybackPhase.ready) {
      return const CommandResult.notReady();
    }
    final request = _requestId;
    final load = _loadId;
    final result = await _operations.submit<PlaybackRuntimeCommandResult>(
      slot: PlaybackOperationSlot.audioTrack,
      deadline: _now() + commandBudget,
      operation: (operation) async {
        bool isCurrent() =>
            _isCommandCurrent(owner, request, load) && operation.isCurrent();
        if (!isCurrent()) throw const _PlaybackSuperseded();
        final result = await _runtime.reloadAudio(
          PlaybackExecutionContext(
            requestId: request,
            runtimeId: _runtime.runtimeId,
            loadId: load,
            deadline: operation.deadline,
            monotonicNow: _now,
            cancelled: Future<void>.value(),
            registerCancellation: (_) {},
            isCurrent: isCurrent,
          ),
        );
        if (!isCurrent()) throw const _PlaybackSuperseded();
        return result;
      },
    );
    return _commandResult(result, 'reloadAudio', PlaybackStage.observing);
  }

  Future<LoadResult> _recover(
    PlaybackOwner owner,
    PlaybackPlan plan, {
    bool sourceEnded = false,
  }) {
    final rejection = _rejectLoad(owner);
    if (rejection != null) return Future.value(rejection);
    final incident = _ensureRecoveryIncident(plan.contentKey)
      ..sourceEnded |= sourceEnded;
    _updateRecoveryClock();
    if (_shouldDeferRecovery(owner)) {
      incident.deferredPlan = plan.withConfiguration(_desiredConfiguration);
      _emitTrace('recovery.deferred', {
        'contentKey': plan.contentKey,
        'playing': owner._playing,
        'inhibitors': _ownerInhibitors[owner]?.length ?? 0,
      });
      _publish();
      return Future.value(const LoadResult.deferred());
    }
    if (_recoveryIncident == incident) {
      incident
        ..deferredPlan = null
        ..sourceEnded = false;
    }
    return _load(
      owner,
      _planForReload(plan),
      start: PlaybackStartPolicy.preserve,
      automaticRecovery: true,
    );
  }

  bool _consumeRecoveryBudget(String contentKey) {
    final incident = _ensureRecoveryIncident(contentKey);
    _updateRecoveryClock();
    if (incident.attempts >= 3 || _recoveryRemaining() <= Duration.zero) {
      return false;
    }
    incident.attempts++;
    incident.lastAttemptAt = _now();
    return true;
  }

  _RecoveryIncident _ensureRecoveryIncident(String contentKey) {
    final current = _recoveryIncident;
    if (current != null && current.contentKey == contentKey) return current;
    final incident = _RecoveryIncident(contentKey);
    _recoveryIncident = incident;
    _updateRecoveryClock();
    return incident;
  }

  bool _shouldDeferRecovery(PlaybackOwner owner) =>
      owner._requiresLoad ||
      _pendingSeekSequence != null ||
      _actual.seeking == true ||
      _sessionInhibitors.isNotEmpty ||
      !owner._playing ||
      (_ownerInhibitors[owner]?.any(
            (token) =>
                token.source != PlaybackInhibitorSource.outputUnavailable,
          ) ??
          false);

  void _updateRecoveryClock([Duration? at]) {
    final incident = _recoveryIncident;
    if (incident == null) return;
    final now = at ?? _now();
    final owner = _activeOwner;
    final active = owner != null && !_shouldDeferRecovery(owner);
    if (active) {
      incident.activeSince ??= now;
      return;
    }
    final activeSince = incident.activeSince;
    if (activeSince != null) {
      incident
        ..activeElapsed += now - activeSince
        ..activeSince = null;
    }
  }

  Duration _recoveryRemaining() {
    final incident = _recoveryIncident;
    if (incident == null) return const Duration(seconds: 30);
    _updateRecoveryClock();
    var elapsed = incident.activeElapsed;
    final since = incident.activeSince;
    if (since != null) elapsed += _now() - since;
    return const Duration(seconds: 30) - elapsed;
  }

  PlaybackFailure _recoveryBudgetFailure() => PlaybackFailure(
    category: PlaybackFailureCategory.network,
    operation: 'automatic-recovery',
    stage: _stage,
    recoverable: false,
    cause: '自动恢复预算已耗尽。',
  );

  void _resumeDeferredRecovery() {
    if (_phase != PlaybackPhase.ready) return;
    final owner = _activeOwner;
    final incident = _recoveryIncident;
    if (owner == null ||
        _shouldDeferRecovery(owner) ||
        (_actual.playing != true && incident?.sourceEnded != true)) {
      return;
    }
    _observeHealth(_now());
    final plan = incident?.deferredPlan;
    if (incident == null || plan == null) return;
    // Let observed healthy media continue for the full recovery-reset window
    // before deciding whether the deferred failure still needs a reload.
    if (_healthySince != null) return;
    incident.deferredPlan = null;
    unawaited(_recover(owner, plan));
  }

  Future<LoadResult> _retry(PlaybackOwner owner) {
    final rejection = _rejectLoad(owner);
    if (rejection != null) return Future.value(rejection);
    final plan = identical(_lastLoadOwner, owner)
        ? _lastLoadPlan ?? _currentPlan
        : _currentPlan;
    if (plan == null) return Future.value(const LoadResult.noMedia());
    _recoveryIncident = null;
    final retryPlan = _planForReload(plan);
    return _load(owner, retryPlan, start: PlaybackStartPolicy.preserve);
  }

  Future<CommandResult> _acknowledgeAction(
    PlaybackOwner owner,
    PlaybackAction action,
  ) async {
    final rejection = _rejectCommand(owner);
    if (rejection != null) return rejection;
    if (_pendingAction == null ||
        _pendingAction!.id != action.id ||
        _pendingAction!.ownerId != owner.id ||
        _pendingAction!.requestId != _requestId) {
      return const CommandResult.superseded();
    }
    _pendingAction = null;
    _publish();
    return const CommandResult.applied();
  }

  void _handleRuntimeEvent(PlaybackRuntimeEvent event) {
    if (_closingRequested || event.runtimeId != _runtime.runtimeId) return;
    if (event.loadId == null &&
        (event is PlaybackRuntimeEnded || event is PlaybackRuntimeFailure)) {
      return;
    }
    if (event.loadId != null && event.loadId != _loadId) return;
    switch (event) {
      case PlaybackRuntimeMediaAnchor(:final anchor, :final seekSequence):
        if (_activeOwner == null ||
            _activeOwner!._requiresLoad ||
            _phase != PlaybackPhase.ready ||
            seekSequence != _seekSequence) {
          return;
        }
        if (anchor.advancing && !_mediaClockMayAdvance) return;
        final previous = _mediaAnchor;
        if (previous != null &&
            (anchor.continuity < previous.continuity ||
                (anchor.continuity == previous.continuity &&
                    anchor.observedAtUs < previous.observedAtUs))) {
          return;
        }
        _mediaAnchor = anchor;
        _mediaAnchors.add(anchor);
      case PlaybackRuntimeStateChanged(:final actual):
        final clockStateChanged =
            _actual.playing != actual.playing ||
            _actual.buffering != actual.buffering ||
            _actual.seeking != actual.seeking;
        _actual = actual;
        if (clockStateChanged) {
          // 恢复时仍保持冻结，取得本次状态之后的新样本再开始外推。
          _freezeMediaAnchor(refreshObservedAt: true);
          if (_mediaClockMayAdvance) {
            if (_runtime case final PlaybackMediaClockSampler sampler) {
              sampler.sampleMediaClock();
            }
          }
        }
        _observeHealth(_now());
        _publish();
        _resumeDeferredRecovery();
      case PlaybackRuntimeCapabilitiesChanged(:final capabilities):
        _capabilities = capabilities;
        _observeHealth(_now());
        _publish();
      case PlaybackRuntimeEnded(:final position, :final duration):
        if (_phase != PlaybackPhase.ready || _pendingAction != null) return;
        final owner = _activeOwner;
        if (owner == null) return;
        final plan = _currentPlan;
        final endPosition = position ?? _runtime.position ?? _actual.position;
        final endDuration = duration != null && duration > Duration.zero
            ? duration
            : plan?.timeline.duration ?? _actual.duration;
        if (plan != null &&
            plan.source.isNetwork &&
            plan.timeline.kind == PlaybackTimelineKind.onDemand &&
            endPosition != null &&
            endDuration != null &&
            endDuration > Duration.zero &&
            endPosition < endDuration - const Duration(seconds: 2)) {
          // 网络点播提前结束仍属于同一次故障，保留用户意图并沿用恢复预算。
          _emitTrace('recovery.premature-eof', {
            'loadId': _loadId,
            'positionMs': endPosition.inMilliseconds,
            'durationMs': endDuration.inMilliseconds,
          });
          unawaited(_recover(owner, plan, sourceEnded: true));
          return;
        }
        // 播完后停止页面的播放意图，返回重载时保持停止；连播由页面显式发起。
        owner._playing = false;
        _intentRevision++;
        _settlePlayingWaiters(const CommandResult.superseded());
        _phase = PlaybackPhase.ended;
        _stage = PlaybackStage.observing;
        _pendingAction = PlaybackAction(
          id: _nextActionId++,
          ownerId: owner.id,
          requestId: _requestId,
          kind: PlaybackActionKind.completed,
        );
        _publish();
      case PlaybackRuntimeFailure(:final failure):
        _publishFailure(failure);
    }
  }

  void _observeHealth(Duration now) {
    final incident = _recoveryIncident;
    _updateRecoveryClock(now);
    if (incident == null || _phase != PlaybackPhase.ready) {
      _healthyCheck?.cancel();
      _healthyCheck = null;
      return;
    }
    final owner = _activeOwner;
    if (owner == null ||
        owner._requiresLoad ||
        _sessionInhibitors.isNotEmpty ||
        !owner._playing ||
        _ownerInhibitors[owner]!.isNotEmpty) {
      // 用户暂停或系统抑制期间保留预算，不用位置推进作为健康条件。
      _healthySince = null;
      _healthyCheck?.cancel();
      _healthyCheck = null;
      return;
    }
    final audioOnly = _currentPlan?.configuration.audioOnly == true;
    final audioRequired = audioOnly || _capabilities.hasAudio == true;
    final videoRequired = !audioOnly && _capabilities.hasVideo == true;
    final knownTracks =
        _capabilities.hasAudio != null &&
        (audioOnly || _capabilities.hasVideo != null);
    final tracksHealthy =
        knownTracks &&
        (!audioRequired || _actual.audioProgressing == true) &&
        (!videoRequired || _actual.videoProgressing == true) &&
        (audioRequired || videoRequired);
    if (!tracksHealthy ||
        _actual.playing != true ||
        _actual.buffering == true) {
      _healthySince = null;
      _healthyCheck?.cancel();
      _healthyCheck = null;
      return;
    }
    if (_healthySince == null) {
      _healthySince = now;
      _scheduleHealthyCheck(const Duration(seconds: 10));
      return;
    }
    if (now - _healthySince! >= const Duration(seconds: 10)) {
      _recoveryIncident = null;
      _healthySince = null;
      _healthyCheck?.cancel();
      _healthyCheck = null;
      _emitTrace('recovery.healthy', {'loadId': _loadId});
    }
  }

  void _scheduleHealthyCheck(Duration remaining) {
    _healthyCheck?.cancel();
    _healthyCheck = Timer(remaining, () {
      _healthyCheck = null;
      _observeHealth(_now());
    });
  }

  void _publishFailure(PlaybackFailure failure) {
    if (_closingRequested || _disposed) return;
    _intentRevision++;
    _settlePlayingWaiters(const CommandResult.superseded());
    _failure = failure;
    _phase = PlaybackPhase.failed;
    _stage = failure.stage;
    _emitTrace('playback.failed', {
      'requestId': _requestId,
      'loadId': _loadId,
      'category': failure.category.name,
      'operation': failure.operation,
    });
    _publish();
    unawaited(_scheduleWriterIfReady());
  }

  void _failLoad(_AcceptedRequest request, PlaybackFailure failure) {
    if (!_ownsRequest(request)) return;
    _failure = failure;
    _phase = PlaybackPhase.failed;
    _stage = failure.stage;
    _writerLoadRequestId = null;
    _finishRequest(request, LoadResult.failed(failure));
    _publish();
  }

  void _expireRequest(_AcceptedRequest request) {
    if (!_ownsRequest(request)) return;
    _cancelRequestCallbacks(request);
    _operations
      ..cancel(PlaybackOperationSlot.load)
      ..cancel(PlaybackOperationSlot.recovery);
    _failLoad(
      request,
      PlaybackFailure(
        category: PlaybackFailureCategory.timeout,
        operation: 'load',
        stage: _stage,
        recoverable: true,
        cause: '加载超过接受时的总时限。',
      ),
    );
  }

  void _finishRequest(_AcceptedRequest request, LoadResult result) {
    request.loaded = result.outcome == LoadOutcome.ready;
    request.timer?.cancel();
    request.timer = null;
    request.cancelCallbacks.clear();
    if (identical(_acceptedRequest, request)) _acceptedRequest = null;
    if (!request.result.isCompleted) request.result.complete(result);
  }

  void _supersedeAcceptedRequest() {
    final request = _acceptedRequest;
    if (request == null) return;
    request.timer?.cancel();
    request.timer = null;
    _cancelRequestCallbacks(request);
    if (!request.result.isCompleted) {
      request.result.complete(const LoadResult.superseded());
    }
    _acceptedRequest = null;
  }

  void _cancelRequestCallbacks(_AcceptedRequest request) {
    request.cancel();
    final callbacks = List<void Function()>.of(request.cancelCallbacks);
    request.cancelCallbacks.clear();
    for (final cancel in callbacks) {
      try {
        cancel();
      } catch (_) {
        // A resolver cancellation callback is advisory; its request guard is authoritative.
      }
    }
  }

  bool _isRequestCurrent(_AcceptedRequest request) =>
      _ownsRequest(request) && request.deadline > _now();

  bool _ownsRequest(_AcceptedRequest request) =>
      !_closingRequested &&
      !_disposed &&
      identical(_acceptedRequest, request) &&
      request.id == _requestId &&
      request.owner.isActive &&
      !request.owner._closed;

  bool _isCommandCurrent(PlaybackOwner owner, int request, int load) =>
      !_closingRequested &&
      !_disposed &&
      !owner._requiresLoad &&
      owner.isActive &&
      request == _requestId &&
      load == _loadId &&
      _phase == PlaybackPhase.ready;

  LoadResult? _rejectLoad(PlaybackOwner owner) {
    if (_closingRequested || _disposed || owner._closed) {
      return const LoadResult.closed();
    }
    if (!owner.isActive) return const LoadResult.inactive();
    return null;
  }

  CommandResult? _rejectCommand(PlaybackOwner owner) {
    if (_closingRequested || _disposed || owner._closed) {
      return const CommandResult.closed();
    }
    if (!owner.isActive) return const CommandResult.inactive();
    return null;
  }

  LoadResult _closedOrInactive(PlaybackOwner owner) =>
      _closingRequested || _disposed || owner._closed
      ? const LoadResult.closed()
      : const LoadResult.inactive();

  CommandResult _commandResult(
    PlaybackOperationResult<PlaybackRuntimeCommandResult> result,
    String operation,
    PlaybackStage stage,
  ) {
    switch (result.outcome) {
      case PlaybackOperationOutcome.completed:
        final value = result.value;
        if (value == null) return const CommandResult.applied();
        if (value.failure != null) return CommandResult.failed(value.failure!);
        return value.applied
            ? const CommandResult.applied()
            : const CommandResult.unsupported();
      case PlaybackOperationOutcome.superseded:
        return const CommandResult.superseded();
      case PlaybackOperationOutcome.timedOut:
        return CommandResult.failed(
          PlaybackFailure(
            category: PlaybackFailureCategory.timeout,
            operation: operation,
            stage: stage,
            recoverable: true,
            cause: '命令超过接受时的时限。',
          ),
        );
      case PlaybackOperationOutcome.closed:
        return const CommandResult.closed();
      case PlaybackOperationOutcome.failed:
        final error = result.error;
        if (error is _PlaybackSuperseded) {
          return const CommandResult.superseded();
        }
        if (error is _PlaybackUnsupported) {
          return const CommandResult.unsupported();
        }
        return CommandResult.failed(
          PlaybackFailure(
            category: PlaybackFailureCategory.unknown,
            operation: operation,
            stage: stage,
            recoverable: false,
            cause: error.toString(),
          ),
        );
    }
  }

  void _activate(PlaybackOwner owner) {
    if (_closingRequested || _disposed || owner._closed || !owner._attached) {
      return;
    }
    if (identical(_activeOwner, owner)) return;
    final previous = _activeOwner;
    if (previous != null) {
      previous
        ..invalidateRequests()
        .._requiresLoad = true;
    }
    _invalidateMediaAnchor();
    _supersedeAcceptedRequest();
    _operations.prioritizeLoad();
    _owners
      ..remove(owner)
      ..add(owner);
    _activeOwner = owner;
    owner._requiresLoad = true;
    _updateRecoveryClock();
    _intentRevision++;
    _settlePlayingWaiters(const CommandResult.superseded());
    _publish();
    _scheduleWriterIfReady();
    _resumeDeferredRecovery();
  }

  void _releaseOwner(PlaybackOwner owner) {
    if (owner._closed) return;
    final wasActive = identical(_activeOwner, owner);
    owner
      .._closed = true
      .._attached = false
      ..invalidateRequests();
    _closeSnapshotStreams(owner);
    owner._inhibitors.clear();
    _ownerInhibitors.remove(owner);
    _owners.remove(owner);
    if (identical(_acceptedRequest?.owner, owner)) _supersedeAcceptedRequest();
    if (wasActive) {
      _invalidateMediaAnchor();
      _operations.prioritizeLoad();
      _activeOwner = null;
      for (final remainingOwner in _owners) {
        remainingOwner._requiresLoad = true;
      }
      _updateRecoveryClock();
      _intentRevision++;
      _settlePlayingWaiters(const CommandResult.superseded());
      _publish();
      _scheduleWriterIfReady();
    }
    if (_owners.isEmpty && _keepAliveCount == 0) _requestShutdown();
  }

  PlaybackKeepAliveLease? _acquireKeepAlive(PlaybackOwner owner) {
    if (owner._closed || !owner._attached || _closingRequested || _disposed) {
      return null;
    }
    _keepAliveCount++;
    return PlaybackKeepAliveLease._(() {
      if (_keepAliveCount > 0) _keepAliveCount--;
      if (_owners.isEmpty && _keepAliveCount == 0) _requestShutdown();
    });
  }

  void _requestShutdown() {
    if (_shutdownStarted || _disposed) return;
    _closingRequested = true;
    _shutdownStarted = true;
    _phase = PlaybackPhase.closing;
    _stage = PlaybackStage.closing;
    _healthyCheck?.cancel();
    _healthyCheck = null;
    _healthySince = null;
    _invalidateMediaAnchor();
    _supersedeAcceptedRequest();
    _operations.dispose();
    _settlePlayingWaiters(const CommandResult.closed());
    _intentRevision++;
    _publish();
    _closeAllSnapshotStreams();
    _shutdownTask = _shutdownRuntime();
    unawaited(_shutdownTask!);
  }

  Future<PlaybackShutdownResult> _shutdownRuntime() async {
    final started = _now();
    Future<PlaybackShutdownResult> cleanup;
    try {
      // Runtime owns the native operation queue and can begin teardown now.
      // A single deadline bounds the result; timing out this await does not
      // cancel the cleanup or release the resource slot.
      cleanup = _runtime.shutdown();
      final remaining = shutdownBudget - (_now() - started);
      if (remaining <= Duration.zero) {
        return _shutdownTimedOut();
      }
      final result = await cleanup.timeout(remaining);
      if (result.outcome == PlaybackShutdownOutcome.cleanupIncomplete) {
        _failure = result.failure;
        _phase = PlaybackPhase.closing;
        _stage = PlaybackStage.closing;
        _publish();
        return result;
      }
      final releaseRemaining = shutdownBudget - (_now() - started);
      if (releaseRemaining <= Duration.zero) return _shutdownTimedOut();
      await _runtime.released.timeout(releaseRemaining);
      _markDisposed();
      return result;
    } on TimeoutException {
      return _shutdownTimedOut();
    } catch (error) {
      final failure = PlaybackFailure(
        category: PlaybackFailureCategory.disposal,
        operation: 'shutdown',
        stage: PlaybackStage.closing,
        recoverable: false,
        cause: error.toString(),
      );
      _failure = failure;
      _phase = PlaybackPhase.closing;
      _stage = PlaybackStage.closing;
      _publish();
      return PlaybackShutdownResult.cleanupIncomplete(failure);
    }
  }

  PlaybackShutdownResult _shutdownTimedOut() {
    const failure = PlaybackFailure(
      category: PlaybackFailureCategory.timeout,
      operation: 'shutdown',
      stage: PlaybackStage.closing,
      recoverable: false,
      cause: '关闭超过首次接受时的总时限；资源仍由 released 屏障跟踪。',
    );
    _failure = failure;
    _phase = PlaybackPhase.closing;
    _stage = PlaybackStage.closing;
    _publish();
    return const PlaybackShutdownResult.cleanupIncomplete(failure);
  }

  void _handleReleased() {
    if (_closingRequested) _markDisposed();
  }

  void _handleReleaseFailure(Object error) {
    if (!_closingRequested) return;
    _failure = PlaybackFailure(
      category: PlaybackFailureCategory.disposal,
      operation: 'runtime.release',
      stage: PlaybackStage.closing,
      recoverable: false,
      cause: error.toString(),
    );
    _phase = PlaybackPhase.closing;
    _stage = PlaybackStage.closing;
    _publish();
  }

  void _markDisposed() {
    if (_disposed) return;
    _phase = PlaybackPhase.disposed;
    _stage = PlaybackStage.idle;
    _failure = null;
    _publish();
    _invalidateMediaAnchor();
    _disposed = true;
    unawaited(_mediaAnchors.close());
    unawaited(_runtimeSubscription?.cancel());
    _runtimeSubscription = null;
    if (!_traceController.isClosed) unawaited(_traceController.close());
  }

  void _publish() {
    if (_disposed) return;
    if (!_mediaClockMayAdvance) _freezeMediaAnchor();
    _snapshot = PlaybackSnapshot(
      snapshotVersion: ++_snapshotVersion,
      phase: _phase,
      stage: _stage,
      requestId: _requestId == 0 ? null : _requestId,
      runtimeId: _runtime.runtimeId,
      loadId: _loadId == 0 ? null : _loadId,
      intent: PlaybackIntent(
        playing: _activeOwner?._playing ?? false,
        playbackSpeed: _desiredConfiguration.playbackSpeed,
      ),
      configuration: PlaybackConfigurationState(
        desired: _desiredConfiguration,
        applied: _appliedConfiguration,
        revisions: _configurationRevisions,
        pending: _configurationPending,
      ),
      inhibitors: {
        ..._sessionInhibitors,
        if (_activeOwner != null) ...?_ownerInhibitors[_activeOwner],
      },
      actual: _actual,
      capabilities: _capabilities,
      presentation: _presentation,
      failure: _failure,
      pendingAction: _pendingAction,
    );
    for (final subscribers in _subscribers.values) {
      for (final subscriber in List<_SnapshotSubscriber>.of(subscribers)) {
        if (subscriber.closed) continue;
        if (subscriber.controller.isPaused) {
          subscriber.latest = _snapshot;
        } else {
          subscriber.controller.add(_snapshot);
        }
      }
    }
  }

  Stream<PlaybackSnapshot> _watch(PlaybackOwner owner) =>
      Stream.multi((controller) {
        if (owner._closed) {
          unawaited(controller.close());
          return;
        }
        final subscriber = _SnapshotSubscriber(owner, controller);
        _subscribers
            .putIfAbsent(owner, () => <_SnapshotSubscriber>[])
            .add(subscriber);
        controller
          ..add(_snapshot)
          ..onPause = () {}
          ..onResume = () {
            if (subscriber.closed) return;
            final latest = subscriber.latest;
            subscriber.latest = null;
            if (latest != null) controller.add(latest);
          }
          ..onCancel = () {
            subscriber.closed = true;
            _subscribers[owner]?.remove(subscriber);
          };
      });

  void _closeSnapshotStreams(PlaybackOwner owner) {
    final subscribers = _subscribers.remove(owner);
    if (subscribers == null) return;
    for (final subscriber in subscribers) {
      subscriber.closed = true;
      unawaited(subscriber.controller.close());
    }
  }

  void _closeAllSnapshotStreams() {
    for (final owner in List<PlaybackOwner>.of(_subscribers.keys)) {
      _closeSnapshotStreams(owner);
    }
  }

  void _emitTrace(String name, Map<String, Object?> fields) {
    if (_traceController.isClosed) return;
    _traceController.add(
      PlaybackSessionTrace(
        name: name,
        monotonicTime: _now(),
        requestId: _requestId,
        loadId: _loadId,
        fields: Map.unmodifiable(fields),
      ),
    );
  }

  bool _sameConfiguration(
    PlaybackConfiguration left,
    PlaybackConfiguration right,
  ) =>
      left.audioOnly == right.audioOnly &&
      left.playbackSpeed == right.playbackSpeed &&
      left.volume == right.volume &&
      left.hwdec == right.hwdec &&
      left.audioTrackId == right.audioTrackId &&
      left.videoTrackId == right.videoTrackId &&
      left.subtitleTrack == right.subtitleTrack &&
      _listEquals(left.shaders, right.shaders) &&
      _mapEquals(left.mediaOptions, right.mediaOptions);

  bool _listEquals<T>(List<T> left, List<T> right) {
    if (identical(left, right)) return true;
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  bool _mapEquals<K, V>(Map<K, V> left, Map<K, V> right) {
    if (identical(left, right)) return true;
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (right[entry.key] != entry.value) return false;
    }
    return true;
  }

  PlaybackConfiguration _copyConfigurationKey(
    PlaybackConfiguration target,
    PlaybackConfiguration source,
    PlaybackConfigurationKey key,
  ) => switch (key) {
    PlaybackConfigurationKey.audioOnly => target.copyWith(
      audioOnly: source.audioOnly,
    ),
    PlaybackConfigurationKey.playbackSpeed => target.copyWith(
      playbackSpeed: source.playbackSpeed,
    ),
    PlaybackConfigurationKey.volume => target.copyWith(volume: source.volume),
    PlaybackConfigurationKey.decoder => target.copyWith(hwdec: source.hwdec),
    PlaybackConfigurationKey.audioTrack => target.copyWith(
      audioTrackId: source.audioTrackId,
      clearAudioTrack: source.audioTrackId == null,
    ),
    PlaybackConfigurationKey.videoTrack => target.copyWith(
      videoTrackId: source.videoTrackId,
      clearVideoTrack: source.videoTrackId == null,
    ),
    PlaybackConfigurationKey.subtitleTrack => target.copyWith(
      subtitleTrack: source.subtitleTrack,
      clearSubtitleTrack: source.subtitleTrack == null,
    ),
    PlaybackConfigurationKey.shaders => target.copyWith(
      shaders: source.shaders,
    ),
    PlaybackConfigurationKey.mediaOptions => target.copyWith(
      mediaOptions: source.mediaOptions,
    ),
  };
}

class PlaybackOwner {
  PlaybackOwner._(this._session, this.id);

  final PlaybackSession _session;
  final int id;
  final Set<PlaybackInhibitorToken> _inhibitors = {};
  int _generation = 0;
  bool _playing = false;
  bool _requiresLoad = true;
  bool _closed = false;
  bool _attached = true;

  bool get isClosed => _closed;
  bool get isActive =>
      !_closed &&
      _attached &&
      !_session.isDisposed &&
      identical(_session._activeOwner, this);
  bool get isQuerying =>
      identical(_session._acceptedRequest?.owner, this) &&
      _session._stage == PlaybackStage.resolving;
  Stream<PlaybackSnapshot> get snapshots => _session._watch(this);

  Future<LoadResult> load(
    PlaybackPlan plan, {
    PlaybackStartPolicy start = PlaybackStartPolicy.preserve,
  }) => _session._load(this, plan, start: start);

  Future<LoadResult> query(
    Future<PlaybackPlan?> Function(PlaybackQuery query) resolve, {
    PlaybackStartPolicy start = PlaybackStartPolicy.preserve,
    bool Function()? shouldLoad,
  }) => _session._query(this, resolve, start: start, shouldLoad: shouldLoad);

  Future<LoadResult> retry() => _session._retry(this);

  Future<LoadResult> recover(PlaybackPlan plan) =>
      _session._recover(this, plan);

  Future<CommandResult> setPlaying(bool playing) =>
      _session._setPlaying(this, playing);

  Future<CommandResult> seek(Duration target) => _session._seek(this, target);

  Future<CommandResult> reloadAudio() => _session._reloadAudio(this);

  Future<CommandResult> setPlaybackSpeed(
    double value, {
    Map<String, String>? mediaOptions,
  }) {
    if (!value.isFinite || value <= 0) {
      return Future.value(
        CommandResult.failed(
          PlaybackFailure(
            category: PlaybackFailureCategory.capability,
            operation: 'playbackSpeed',
            stage: _session._stage,
            recoverable: false,
            cause: '倍速必须为有限正数。',
          ),
        ),
      );
    }
    return _session._setConfiguration(
      this,
      PlaybackConfigurationKey.playbackSpeed,
      PlaybackOperationSlot.playbackSpeed,
      (current) => current.copyWith(
        playbackSpeed: value,
        mediaOptions: mediaOptions,
      ),
      alsoChanged: mediaOptions == null
          ? const {}
          : const {PlaybackConfigurationKey.mediaOptions},
    );
  }

  Future<CommandResult> setVolume(double value) {
    if (!value.isFinite || value < 0 || value > 100) {
      return Future.value(
        CommandResult.failed(
          PlaybackFailure(
            category: PlaybackFailureCategory.capability,
            operation: 'volume',
            stage: _session._stage,
            recoverable: false,
            cause: '音量必须在 0 到 100 之间。',
          ),
        ),
      );
    }
    return _session._setConfiguration(
      this,
      PlaybackConfigurationKey.volume,
      PlaybackOperationSlot.volume,
      (current) => current.copyWith(volume: value),
    );
  }

  Future<CommandResult> setAudioOnly(bool value) => _session._setConfiguration(
    this,
    PlaybackConfigurationKey.audioOnly,
    PlaybackOperationSlot.audioOnly,
    (current) => current.copyWith(audioOnly: value),
  );

  Future<CommandResult> setAudioTrack(int? trackId) =>
      _session._setConfiguration(
        this,
        PlaybackConfigurationKey.audioTrack,
        PlaybackOperationSlot.audioTrack,
        (current) => current.copyWith(
          audioTrackId: trackId,
          clearAudioTrack: trackId == null,
        ),
      );

  Future<CommandResult> setSubtitleTrack(PlaybackSubtitleTrack? track) =>
      _session._setConfiguration(
        this,
        PlaybackConfigurationKey.subtitleTrack,
        PlaybackOperationSlot.subtitleTrack,
        (current) => current.copyWith(
          subtitleTrack: track,
          clearSubtitleTrack: track == null,
        ),
      );

  Future<CommandResult> setDecoder(PlaybackDecoder decoder) =>
      _session._setConfiguration(
        this,
        PlaybackConfigurationKey.decoder,
        PlaybackOperationSlot.decoder,
        (current) => current.copyWith(hwdec: decoder.value),
      );

  Future<CommandResult> setShader(List<String> shaders) =>
      _session._setConfiguration(
        this,
        PlaybackConfigurationKey.shaders,
        PlaybackOperationSlot.shader,
        (current) => current.copyWith(shaders: shaders),
      );

  PlaybackInhibitorToken? acquireInhibitor(PlaybackInhibitorSource source) =>
      _session._acquireInhibitor(this, source);

  Future<CommandResult> releaseInhibitor(PlaybackInhibitorToken token) =>
      _session._releaseInhibitor(this, token);

  Future<CommandResult> acknowledgeAction(PlaybackAction action) =>
      _session._acknowledgeAction(this, action);

  PlaybackKeepAliveLease? acquireKeepAlive() =>
      _session._acquireKeepAlive(this);

  bool Function() guard() {
    final generation = _generation;
    return () => isActive && generation == _generation;
  }

  void activate() => _session._activate(this);

  void close() => _session._releaseOwner(this);

  void invalidateRequests() {
    _generation++;
  }
}

class PlaybackKeepAliveLease {
  PlaybackKeepAliveLease._(this._release);

  final void Function() _release;
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    _release();
  }
}

class PlaybackSessionTrace {
  PlaybackSessionTrace({
    required this.name,
    required this.monotonicTime,
    required this.requestId,
    required this.loadId,
    required Map<String, Object?> fields,
  }) : fields = Map.unmodifiable(fields);

  final String name;
  final Duration monotonicTime;
  final int requestId;
  final int loadId;
  final Map<String, Object?> fields;
}

class _AcceptedRequest {
  _AcceptedRequest({
    required this.id,
    required this.owner,
    required this.deadline,
    required this.configurationRevisionsAtAcceptance,
  });

  final int id;
  final PlaybackOwner owner;
  final Duration deadline;
  final Map<PlaybackConfigurationKey, int> configurationRevisionsAtAcceptance;
  final Completer<LoadResult> result = Completer<LoadResult>();
  final Completer<void> cancelled = Completer<void>();
  final List<void Function()> cancelCallbacks = [];
  Timer? timer;
  int? loadId;
  PlaybackPlan? finalPlan;
  bool loaded = false;
  bool resolved = false;
  bool Function()? shouldLoad;
  bool recovery = false;

  void registerCancel(void Function() cancel) {
    if (cancelled.isCompleted) {
      cancel();
    } else {
      cancelCallbacks.add(cancel);
    }
  }

  void cancel() {
    if (!cancelled.isCompleted) cancelled.complete();
  }
}

class _RecoveryIncident {
  _RecoveryIncident(this.contentKey);

  final String contentKey;
  Duration activeElapsed = Duration.zero;
  Duration? activeSince;
  int attempts = 0;
  Duration? lastAttemptAt;
  PlaybackPlan? deferredPlan;
  // EOF 后原生已停止，延期恢复仍由用户的播放意图决定。
  bool sourceEnded = false;
}

class _SnapshotSubscriber {
  _SnapshotSubscriber(this.owner, this.controller);

  final PlaybackOwner owner;
  final MultiStreamController<PlaybackSnapshot> controller;
  PlaybackSnapshot? latest;
  bool closed = false;
}

class _PlaybackSuperseded implements Exception {
  const _PlaybackSuperseded();
}

class _PlaybackUnsupported implements Exception {
  const _PlaybackUnsupported();
}
