import 'dart:async';

import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';

enum PlaybackStartPolicy { play, pause, preserve }

enum PlaybackTimelineKind { onDemand, live, local }

enum PlaybackSeekPolicy { allowed, disabled, unknown }

enum PlaybackPhase {
  idle,
  loading,
  ready,
  recovering,
  ended,
  failed,
  closing,
  disposed,
}

enum PlaybackStage {
  idle,
  resolving,
  queued,
  initializing,
  recovering,
  opening,
  metadata,
  outputPreparing,
  loaded,
  reconcilingIntent,
  observing,
  closing,
}

enum PlaybackFailureCategory {
  source,
  metadata,
  output,
  decoder,
  audio,
  network,
  capability,
  disposal,
  timeout,
  unknown,
}

enum PlaybackOutputStrategy {
  unknown,
  prepared,
  noVideo,
  legacyAttached,
  failed,
}

enum PlaybackSeekSupport { unknown, unsupported, supported }

enum PlaybackInhibitorSource {
  audioFocus,
  backgroundPolicy,
  outputUnavailable,
  system,
}

enum PlaybackConfigurationKey {
  audioOnly,
  playbackSpeed,
  volume,
  decoder,
  audioTrack,
  videoTrack,
  subtitleTrack,
  shaders,
  mediaOptions,
}

/// 一次播放来源的不可变快照。候选切换只产生新对象，不改写已提交计划。
class PlaybackSourceSnapshot {
  PlaybackSourceSnapshot._({
    required this.videoCandidates,
    required this.audioCandidates,
    required this.videoIndex,
    required this.audioIndex,
    required this.candidateIndex,
    required this.isNetwork,
    required Map<String, String> headers,
    this._fileSource,
  }) : headers = Map.unmodifiable(headers);

  factory PlaybackSourceSnapshot.fromDataSource(
    DataSource source, {
    Map<String, String> headers = const {},
  }) {
    if (source is NetworkSource) {
      return PlaybackSourceSnapshot._(
        videoCandidates: List.unmodifiable(source.videoCandidates),
        audioCandidates: List.unmodifiable(source.audioCandidates),
        videoIndex: 0,
        audioIndex: 0,
        candidateIndex: 0,
        isNetwork: true,
        headers: headers,
      );
    }
    final audioSource = source.audioSource;
    final audioCandidates = audioSource != null && audioSource.isNotEmpty
        ? [audioSource]
        : const <String>[];
    return PlaybackSourceSnapshot._(
      videoCandidates: List.unmodifiable([source.videoSource]),
      audioCandidates: List.unmodifiable(audioCandidates),
      videoIndex: 0,
      audioIndex: 0,
      candidateIndex: 0,
      isNetwork: false,
      headers: headers,
      fileSource: source is FileSource ? source : null,
    );
  }

  final List<String> videoCandidates;
  final List<String> audioCandidates;
  final int videoIndex;
  final int audioIndex;
  final int candidateIndex;
  final bool isNetwork;
  final Map<String, String> headers;
  final FileSource? _fileSource;

  String get currentVideoSource => videoCandidates[videoIndex];

  String? get currentAudioSource =>
      audioCandidates.isEmpty ? null : audioCandidates[audioIndex];

  FileSource? get fileSource => _fileSource;

  PlaybackSourceSnapshot? advanceCandidate({bool audioOnly = false}) {
    var nextVideo = videoIndex;
    var nextAudio = audioIndex;
    if (audioIndex + 1 < audioCandidates.length) {
      nextAudio++;
    } else if ((!audioOnly || audioCandidates.isEmpty) &&
        videoIndex + 1 < videoCandidates.length) {
      nextVideo++;
      nextAudio = 0;
    } else {
      return null;
    }
    return PlaybackSourceSnapshot._(
      videoCandidates: videoCandidates,
      audioCandidates: audioCandidates,
      videoIndex: nextVideo,
      audioIndex: nextAudio,
      candidateIndex: candidateIndex + 1,
      isNetwork: isNetwork,
      headers: headers,
      fileSource: _fileSource,
    );
  }
}

class PlaybackTimeline {
  const PlaybackTimeline({
    required this.kind,
    required this.seekPolicy,
    this.duration,
  });

  final PlaybackTimelineKind kind;
  final PlaybackSeekPolicy seekPolicy;
  final Duration? duration;
}

/// 已由装配层解析并冻结的媒体配置。
class PlaybackConfiguration {
  PlaybackConfiguration({
    this.audioOnly = false,
    this.playbackSpeed = 1,
    this.volume = 100,
    this.hwdec = 'auto',
    this.audioTrackId,
    this.videoTrackId,
    this.subtitleTrack,
    Iterable<String> shaders = const [],
    Map<String, String> mediaOptions = const {},
  }) : shaders = List.unmodifiable(shaders),
       mediaOptions = Map.unmodifiable(mediaOptions);

  final bool audioOnly;
  final double playbackSpeed;
  final double volume;
  final String hwdec;
  final int? audioTrackId;
  final int? videoTrackId;
  final PlaybackSubtitleTrack? subtitleTrack;
  final List<String> shaders;
  final Map<String, String> mediaOptions;

  PlaybackConfiguration copyWith({
    bool? audioOnly,
    double? playbackSpeed,
    double? volume,
    String? hwdec,
    int? audioTrackId,
    bool clearAudioTrack = false,
    int? videoTrackId,
    bool clearVideoTrack = false,
    PlaybackSubtitleTrack? subtitleTrack,
    bool clearSubtitleTrack = false,
    Iterable<String>? shaders,
    Map<String, String>? mediaOptions,
  }) => PlaybackConfiguration(
    audioOnly: audioOnly ?? this.audioOnly,
    playbackSpeed: playbackSpeed ?? this.playbackSpeed,
    volume: volume ?? this.volume,
    hwdec: hwdec ?? this.hwdec,
    audioTrackId: clearAudioTrack ? null : audioTrackId ?? this.audioTrackId,
    videoTrackId: clearVideoTrack ? null : videoTrackId ?? this.videoTrackId,
    subtitleTrack: clearSubtitleTrack
        ? null
        : subtitleTrack ?? this.subtitleTrack,
    shaders: shaders ?? this.shaders,
    mediaOptions: mediaOptions ?? this.mediaOptions,
  );
}

/// Subtitle selection can be an mpv track, an external URI, or explicit none.
/// Null in [PlaybackConfiguration] means mpv auto-select.
class PlaybackSubtitleTrack {
  const PlaybackSubtitleTrack({
    required this.id,
    this.title,
    this.language,
    this.uri = false,
  });

  const PlaybackSubtitleTrack.no() : this(id: 'no');
  const PlaybackSubtitleTrack.auto() : this(id: 'auto');
  const PlaybackSubtitleTrack.external(
    String uri, {
    String? title,
    String? language,
  }) : this(id: uri, title: title, language: language, uri: true);

  final String id;
  final String? title;
  final String? language;
  final bool uri;

  @override
  bool operator ==(Object other) =>
      other is PlaybackSubtitleTrack &&
      id == other.id &&
      title == other.title &&
      language == other.language &&
      uri == other.uri;

  @override
  int get hashCode => Object.hash(id, title, language, uri);
}

class PlaybackMetadataHint {
  const PlaybackMetadataHint({
    required this.trust,
    this.width,
    this.height,
    this.rotation,
    this.pixelAspectRatio,
    this.cropKnownNone,
    this.duration,
  });

  final PlaybackMetadataTrust trust;
  final int? width;
  final int? height;
  final int? rotation;
  final double? pixelAspectRatio;
  final bool? cropKnownNone;
  final Duration? duration;
}

enum PlaybackMetadataTrust { unknown, sourceHint, confirmed }

class PlaybackPlan {
  PlaybackPlan({
    required this.contentKey,
    required this.source,
    required this.timeline,
    required this.configuration,
    this.startPosition,
    this.reloadPosition,
    this.metadata,
  });

  final String contentKey;
  final PlaybackSourceSnapshot source;
  final PlaybackTimeline timeline;
  final PlaybackConfiguration configuration;
  final Duration? startPosition;
  final Duration? reloadPosition;
  final PlaybackMetadataHint? metadata;

  PlaybackPlan withSource(PlaybackSourceSnapshot value) => PlaybackPlan(
    contentKey: contentKey,
    source: value,
    timeline: timeline,
    configuration: configuration,
    startPosition: startPosition,
    reloadPosition: reloadPosition,
    metadata: metadata,
  );

  PlaybackPlan withConfiguration(PlaybackConfiguration value) => PlaybackPlan(
    contentKey: contentKey,
    source: source,
    timeline: timeline,
    configuration: value,
    startPosition: startPosition,
    reloadPosition: reloadPosition,
    metadata: metadata,
  );
}

class PlaybackQuery {
  PlaybackQuery({
    required this.requestId,
    required this._isCurrent,
    required this._registerCancel,
  });

  final int requestId;
  final bool Function() _isCurrent;
  final void Function(void Function() cancel) _registerCancel;

  /// 成功加载后仍可用于当前媒体的页面、字幕等回写；新请求或 owner 失效后结束。
  bool get isCurrent => _isCurrent();

  void registerCancel(void Function() cancel) => _registerCancel(cancel);
}

class PlaybackIntent {
  const PlaybackIntent({this.playing = false, this.playbackSpeed = 1});

  final bool playing;
  final double playbackSpeed;
}

class PlaybackInhibitorToken {
  const PlaybackInhibitorToken({required this.source, required this.id});

  final PlaybackInhibitorSource source;
  final int id;

  @override
  bool operator ==(Object other) =>
      other is PlaybackInhibitorToken &&
      source == other.source &&
      id == other.id;

  @override
  int get hashCode => Object.hash(source, id);
}

class PlaybackActual {
  const PlaybackActual({
    this.playing,
    this.buffering,
    this.seeking,
    this.position,
    this.duration,
    this.audioProgressing,
    this.videoProgressing,
  });

  final bool? playing;
  final bool? buffering;
  final bool? seeking;
  final Duration? position;
  final Duration? duration;

  /// 仅由具备连续原生轨道健康证据的 runtime 填充。
  final bool? audioProgressing;
  final bool? videoProgressing;
}

class PlaybackCapabilities {
  const PlaybackCapabilities({
    this.seekSupport = PlaybackSeekSupport.unknown,
    this.seekStart,
    this.seekEnd,
    this.hasVideo,
    this.hasAudio,
  });

  final PlaybackSeekSupport seekSupport;
  final Duration? seekStart;
  final Duration? seekEnd;
  final bool? hasVideo;
  final bool? hasAudio;
}

class PlaybackPresentation {
  const PlaybackPresentation({
    this.outputStrategy = PlaybackOutputStrategy.unknown,
    this.evidence,
    this.outputEpoch,
    this.width,
    this.height,
    this.frameConsumed,
  });

  final PlaybackOutputStrategy outputStrategy;
  final String? evidence;
  final int? outputEpoch;
  final int? width;
  final int? height;
  final bool? frameConsumed;
}

class PlaybackFailure {
  const PlaybackFailure({
    required this.category,
    required this.operation,
    required this.stage,
    required this.recoverable,
    required this.cause,
  });

  final PlaybackFailureCategory category;
  final String operation;
  final PlaybackStage stage;
  final bool recoverable;
  final String cause;
}

class PlaybackConfigurationState {
  PlaybackConfigurationState({
    required this.desired,
    required this.applied,
    Map<PlaybackConfigurationKey, int> revisions = const {},
    Set<PlaybackConfigurationKey> pending = const {},
  }) : revisions = Map.unmodifiable(revisions),
       pending = Set.unmodifiable(pending);

  static final empty = PlaybackConfigurationState(
    desired: PlaybackConfiguration(),
    applied: PlaybackConfiguration(),
  );

  final PlaybackConfiguration desired;
  final PlaybackConfiguration applied;
  final Map<PlaybackConfigurationKey, int> revisions;
  final Set<PlaybackConfigurationKey> pending;
}

class PlaybackSnapshot {
  PlaybackSnapshot({
    required this.snapshotVersion,
    required this.phase,
    required this.stage,
    required this.intent,
    PlaybackConfigurationState? configuration,
    required this.actual,
    required this.capabilities,
    required this.presentation,
    Set<PlaybackInhibitorToken> inhibitors = const {},
    this.requestId,
    this.runtimeId,
    this.loadId,
    this.failure,
    this.pendingAction,
  }) : configuration = configuration ?? PlaybackConfigurationState.empty,
       inhibitors = Set.unmodifiable(inhibitors);

  final int snapshotVersion;
  final PlaybackPhase phase;
  final PlaybackStage stage;
  final int? requestId;
  final int? runtimeId;
  final int? loadId;
  final PlaybackIntent intent;
  final PlaybackConfigurationState configuration;
  final Set<PlaybackInhibitorToken> inhibitors;
  final PlaybackActual actual;
  final PlaybackCapabilities capabilities;
  final PlaybackPresentation presentation;
  final PlaybackFailure? failure;
  final PlaybackAction? pendingAction;
}

class PlaybackAction {
  const PlaybackAction({
    required this.id,
    required this.ownerId,
    required this.requestId,
    required this.kind,
  });

  final int id;
  final int ownerId;
  final int requestId;
  final PlaybackActionKind kind;
}

enum PlaybackActionKind { completed }

enum LoadOutcome {
  ready,
  noMedia,
  deferred,
  superseded,
  inactive,
  closed,
  failed,
}

class LoadResult {
  const LoadResult._(this.outcome, {this.loadId, this.failure});

  const LoadResult.ready(int loadId)
    : this._(LoadOutcome.ready, loadId: loadId);
  const LoadResult.noMedia() : this._(LoadOutcome.noMedia);
  const LoadResult.deferred() : this._(LoadOutcome.deferred);
  const LoadResult.superseded() : this._(LoadOutcome.superseded);
  const LoadResult.inactive() : this._(LoadOutcome.inactive);
  const LoadResult.closed() : this._(LoadOutcome.closed);
  const LoadResult.failed(PlaybackFailure failure)
    : this._(LoadOutcome.failed, failure: failure);

  final LoadOutcome outcome;
  final int? loadId;
  final PlaybackFailure? failure;
}

enum CommandOutcome {
  applied,
  accepted,
  notReady,
  unsupported,
  capabilityPending,
  outOfRange,
  noMedia,
  superseded,
  inactive,
  closed,
  failed,
}

class CommandResult {
  const CommandResult._(this.outcome, {this.failure});

  const CommandResult.applied() : this._(CommandOutcome.applied);
  const CommandResult.accepted() : this._(CommandOutcome.accepted);
  const CommandResult.notReady() : this._(CommandOutcome.notReady);
  const CommandResult.unsupported() : this._(CommandOutcome.unsupported);
  const CommandResult.capabilityPending()
    : this._(CommandOutcome.capabilityPending);
  const CommandResult.outOfRange() : this._(CommandOutcome.outOfRange);
  const CommandResult.noMedia() : this._(CommandOutcome.noMedia);
  const CommandResult.superseded() : this._(CommandOutcome.superseded);
  const CommandResult.inactive() : this._(CommandOutcome.inactive);
  const CommandResult.closed() : this._(CommandOutcome.closed);
  const CommandResult.failed(PlaybackFailure failure)
    : this._(CommandOutcome.failed, failure: failure);

  final CommandOutcome outcome;
  final PlaybackFailure? failure;
}

enum PlaybackDecoderKind { auto, hardware, software, custom }

class PlaybackDecoder {
  const PlaybackDecoder(this.value, {this.kind = PlaybackDecoderKind.custom});

  final String value;
  final PlaybackDecoderKind kind;
}

class PlaybackRuntimeConfig {
  PlaybackRuntimeConfig({
    required Map<String, String> playerOptions,
    required this.hardwareAccelerationEnabled,
    required this.hardwareDecoder,
    this.width,
    this.height,
    this.enableAndroidTextureScaling = false,
    this.readAndroidTextureScaling,
  }) : playerOptions = Map.unmodifiable(playerOptions);

  final Map<String, String> playerOptions;
  final bool hardwareAccelerationEnabled;
  final String hardwareDecoder;
  final int? width;
  final int? height;
  final bool enableAndroidTextureScaling;
  final bool Function()? readAndroidTextureScaling;
}

class PlaybackExecutionContext {
  const PlaybackExecutionContext({
    required this.requestId,
    required this.runtimeId,
    required this.loadId,
    required this.isCurrent,
    required this.deadline,
    required this.monotonicNow,
    required this.cancelled,
    required this.registerCancellation,
    this.seekSequence = 0,
  });

  final int requestId;
  final int runtimeId;
  final int loadId;
  final int seekSequence;
  final bool Function() isCurrent;
  final Duration deadline;
  final Duration Function() monotonicNow;
  final Future<void> cancelled;
  final void Function(void Function() cancel) registerCancellation;
}

class PlaybackOutputPreparation {
  const PlaybackOutputPreparation({
    required this.strategy,
    required this.evidence,
    required this.outputEpoch,
    this.width,
    this.height,
    this.hasVideo,
  });

  final PlaybackOutputStrategy strategy;
  final String evidence;
  final int outputEpoch;
  final int? width;
  final int? height;
  final bool? hasVideo;
}

class PlaybackRuntimeLoadResult {
  const PlaybackRuntimeLoadResult({
    required this.loaded,
    required this.output,
    this.failure,
    this.capabilities,
  });

  final bool loaded;
  final PlaybackOutputPreparation output;
  final PlaybackFailure? failure;
  final PlaybackCapabilities? capabilities;
}

class PlaybackRuntimeCommandResult {
  const PlaybackRuntimeCommandResult({this.applied = true, this.failure});

  final bool applied;
  final PlaybackFailure? failure;
}

enum PlaybackShutdownOutcome { released, cleanupIncomplete }

class PlaybackShutdownResult {
  const PlaybackShutdownResult._(this.outcome, {this.failure});

  const PlaybackShutdownResult.released()
    : this._(PlaybackShutdownOutcome.released);
  const PlaybackShutdownResult.cleanupIncomplete(PlaybackFailure failure)
    : this._(PlaybackShutdownOutcome.cleanupIncomplete, failure: failure);

  final PlaybackShutdownOutcome outcome;
  final PlaybackFailure? failure;
}

/// Session 面向运行时的 seam；生产 adapter 是 NativePlaybackRuntime。
abstract interface class PlaybackMediaClockSampler {
  void sampleMediaClock();
}

abstract interface class PlaybackSeekSubmissionGate {
  bool get seekSubmissionBlocked;
  Stream<void> get seekSubmissionChanges;
}

abstract interface class PlaybackRuntimePort {
  int get runtimeId;

  /// 当前原生进度，供提交重载前冻结续播位置。
  Duration? get position;

  /// Whether changing shaders on the active output would reset its renderer.
  bool get shaderChangeRequiresRendererReset;
  Stream<PlaybackRuntimeEvent> get events;
  Future<PlaybackRuntimeLoadResult> load(
    PlaybackPlan plan,
    PlaybackExecutionContext context,
  );
  Future<PlaybackRuntimeCommandResult> setPlaying(
    bool playing,
    PlaybackExecutionContext context,
  );
  Future<PlaybackRuntimeCommandResult> seek(
    Duration target,
    PlaybackExecutionContext context,
  );
  Future<PlaybackRuntimeCommandResult> setPlaybackSpeed(
    double value,
    Map<String, String> mediaOptions,
    PlaybackExecutionContext context,
  );
  Future<PlaybackRuntimeCommandResult> setVolume(
    double value,
    PlaybackExecutionContext context,
  );
  Future<PlaybackRuntimeCommandResult> setAudioOnly(
    bool value,
    PlaybackExecutionContext context,
  );
  Future<PlaybackRuntimeCommandResult> setAudioTrack(
    int? trackId,
    PlaybackExecutionContext context,
  );
  Future<PlaybackRuntimeCommandResult> reloadAudio(
    PlaybackExecutionContext context,
  );
  Future<PlaybackRuntimeCommandResult> setSubtitleTrack(
    PlaybackSubtitleTrack? track,
    PlaybackExecutionContext context,
  );
  Future<PlaybackRuntimeCommandResult> setDecoder(
    PlaybackDecoder decoder,
    PlaybackExecutionContext context,
  );
  Future<PlaybackRuntimeCommandResult> setShader(
    List<String> shaders,
    PlaybackExecutionContext context,
  );
  Future<PlaybackShutdownResult> shutdown();
  Future<void> get released;
}

sealed class PlaybackRuntimeEvent {
  const PlaybackRuntimeEvent({required this.runtimeId, this.loadId});

  final int runtimeId;
  final int? loadId;
}

class PlaybackRuntimeMediaAnchor extends PlaybackRuntimeEvent {
  const PlaybackRuntimeMediaAnchor({
    required super.runtimeId,
    required int super.loadId,
    required this.seekSequence,
    required this.anchor,
  });

  final int seekSequence;
  final PlaybackMediaAnchor anchor;
}

class PlaybackRuntimeStateChanged extends PlaybackRuntimeEvent {
  const PlaybackRuntimeStateChanged({
    required super.runtimeId,
    required this.actual,
    super.loadId,
  });

  final PlaybackActual actual;
}

class PlaybackRuntimeCapabilitiesChanged extends PlaybackRuntimeEvent {
  const PlaybackRuntimeCapabilitiesChanged({
    required super.runtimeId,
    required this.capabilities,
    super.loadId,
  });

  final PlaybackCapabilities capabilities;
}

class PlaybackRuntimeEnded extends PlaybackRuntimeEvent {
  const PlaybackRuntimeEnded({
    required super.runtimeId,
    required super.loadId,
    this.position,
    this.duration,
  });

  final Duration? position;
  final Duration? duration;
}

class PlaybackRuntimeFailure extends PlaybackRuntimeEvent {
  const PlaybackRuntimeFailure({
    required super.runtimeId,
    required super.loadId,
    required this.failure,
  });

  final PlaybackFailure failure;
}
