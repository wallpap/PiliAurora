import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_playback_runtime.dart';
import 'package:pili_aurora/plugin/pl_player/playback/network_recovery.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDownAll(Diagnostics.instance.dispose);

  test('keep-open EOF 按文件归属通知，重复事件合并且 seek 后可再次结束', () async {
    final fixture = _Fixture();
    addTearDown(fixture.close);
    final ended = <PlaybackRuntimeEnded>[];
    final subscription = fixture.runtime.events.listen((event) {
      if (event is PlaybackRuntimeEnded) ended.add(event);
    });
    addTearDown(subscription.cancel);
    expect((await fixture.load()).loaded, isTrue);
    void eof(int? entryId, bool reached) => fixture.player.events.add(
      NativePlaybackEof(
        playlistEntryId: entryId,
        reached: reached,
        position: const Duration(seconds: 9),
        duration: const Duration(seconds: 10),
      ),
    );
    eof(null, true);
    eof(6, true);
    await _turn();
    expect(ended, isEmpty);
    eof(7, true);
    eof(7, true);
    await _turn();
    expect(ended, hasLength(1));
    expect(ended.single.position, const Duration(seconds: 9));
    expect(ended.single.duration, const Duration(seconds: 10));
    // 卸载时归零的属性不能覆盖终态续播位置。
    fixture.player.state.position = Duration.zero;
    expect(fixture.runtime.position, const Duration(seconds: 9));
    eof(7, false);
    eof(7, true);
    fixture.player.events.add(
      const NativeEndFile(
        playlistEntryId: 7,
        reason: NativeEndFileReason.eof,
        error: 0,
      ),
    );
    await _turn();
    expect(ended, hasLength(2));
  });

  test('播放位置和实际出帧持续推进时不误触发画面停滞重载', () async {
    final fixture = _Fixture(subscribeToPlaybackEvents: true);
    addTearDown(fixture.close);
    final loaded = await fixture.load();
    expect(
      loaded.loaded,
      isTrue,
      reason: '${loaded.failure?.cause}: ${loaded.output.evidence}',
    );
    await fixture.advance();
    await fixture.advance();
    fixture.player.startPlaying();

    for (var i = 0; i < 24; i++) {
      await fixture.advance();
    }
    expect(fixture.reloads, 0);
    expect(fixture.actual.videoProgressing, isTrue);

    // 主时钟仍推进，实际出帧停止后仍须触发恢复。
    for (var i = 0; i < 24; i++) {
      await fixture.advance(consumeFrame: false);
    }
    expect(fixture.actual.videoProgressing, isFalse);
    expect(fixture.reloads, 1);
  });

  test('实际出帧继续但播放位置停止推进时仍判定停滞', () async {
    final fixture = _Fixture(subscribeToPlaybackEvents: true);
    addTearDown(fixture.close);
    final loaded = await fixture.load();
    expect(
      loaded.loaded,
      isTrue,
      reason: '${loaded.failure?.cause}: ${loaded.output.evidence}',
    );
    await fixture.advance();
    await fixture.advance();
    fixture.player.startPlaying();
    for (var i = 0; i < 4; i++) {
      await fixture.advance();
    }
    expect(fixture.actual.videoProgressing, isTrue);
    for (var i = 0; i < 24; i++) {
      await fixture.advance(advancePosition: false);
    }
    expect(fixture.actual.videoProgressing, isFalse);
    expect(fixture.reloads, 1);
  });

  test('暂停和向后 seek 期间不重载，恢复后重建画面健康证据', () async {
    final fixture = _Fixture(subscribeToPlaybackEvents: true);
    addTearDown(fixture.close);
    expect((await fixture.load()).loaded, isTrue);
    await fixture.advance();
    await fixture.advance();
    fixture.player.startPlaying();
    expect(fixture.actual.videoProgressing, isTrue);

    fixture.player.setPlaying(false);
    for (var i = 0; i < 12; i++) {
      await fixture.advance(consumeFrame: false, advancePosition: false);
    }
    expect(fixture.reloads, 0);
    fixture.player.startPlaying();
    await fixture.advance();
    await fixture.advance();
    expect(fixture.actual.videoProgressing, isTrue);
    expect(fixture.reloads, 0);

    fixture.player.emitProperty('seeking', 'yes');
    fixture.player.state.position = const Duration(milliseconds: 100);
    for (var i = 0; i < 12; i++) {
      await fixture.advance(consumeFrame: false, advancePosition: false);
    }
    expect(fixture.reloads, 0);
    fixture.player.emitProperty('seeking', 'no');
    await fixture.advance();
    await fixture.advance();
    expect(fixture.actual.videoProgressing, isTrue);
    expect(fixture.reloads, 0);
  });

  test('旧加载的迟到帧不能掩盖当前画面停滞', () async {
    final fixture = _Fixture(subscribeToPlaybackEvents: true);
    addTearDown(fixture.close);
    expect((await fixture.load()).loaded, isTrue);
    await fixture.advance();
    await fixture.advance();
    fixture.player.startPlaying();
    expect(fixture.actual.videoProgressing, isTrue);
    final current = fixture.output.token!;
    final stale = OutputOperationToken(
      runtimeId: current.runtimeId,
      loadId: current.loadId - 1,
      outputEpoch: current.outputEpoch,
      configRevision: current.configRevision,
    );
    for (var i = 0; i < 12; i++) {
      await fixture.advance(frameToken: stale);
    }
    expect(fixture.actual.videoProgressing, isFalse);
    expect(fixture.reloads, 1);
  });

  for (final stopTimesOut in [false, true]) {
    test('stop ${stopTimesOut ? '回执超时' : '成功'}后等待完整卸载和输出回执再销毁', () async {
      final fixture = _Fixture();
      addTearDown(fixture.close);
      expect((await fixture.load()).loaded, isTrue);
      fixture.player.stopTimesOut = stopTimesOut;

      final shutdown = fixture.runtime.shutdown();
      await _turn();
      expect(fixture.output.releaseCalls, 0);
      await fixture.player.unload();
      await _turn();
      expect(fixture.output.releaseCalls, 0);
      fixture.player.endFile();
      await _turn();
      expect(fixture.output.releaseCalls, 1);
      expect(fixture.player.disposed, isFalse);

      fixture.output.releaseReceipt.complete();
      expect((await shutdown).outcome, PlaybackShutdownOutcome.released);
      await fixture.runtime.released;
      expect(fixture.events, [
        'stop',
        'invalidate',
        'invalidate',
        'release-output',
        'dispose-player',
      ]);
    });
  }

  test('open 回执失败后关闭仍等待迟到的文件身份和卸载证据', () async {
    final fixture = _Fixture();
    addTearDown(fixture.close);
    fixture.player.openTimesOut = true;
    expect((await fixture.load()).loaded, isFalse);

    final shutdown = fixture.runtime.shutdown();
    await _turn();
    expect(fixture.output.releaseCalls, 0);
    expect(fixture.player.disposed, isFalse);

    fixture.player.startFile();
    await _turn();
    expect(fixture.events, ['stop']);
    await fixture.player.unload();
    fixture.player.endFile();
    await _turn();
    expect(fixture.output.releaseCalls, 1);
    fixture.output.releaseReceipt.complete();
    expect((await shutdown).outcome, PlaybackShutdownOutcome.released);
    await fixture.runtime.released;
    expect(fixture.events.last, 'dispose-player');
  });

  test('open 尚未提交加载就失败时关闭不等待文件身份', () async {
    final fixture = _Fixture();
    addTearDown(fixture.close);
    fixture.player.openFailsBeforeSubmission = true;
    final load = await fixture.load();
    expect(load.loaded, isFalse);
    expect(load.failure?.category, PlaybackFailureCategory.timeout);

    final shutdown = fixture.runtime.shutdown();
    await _turn();
    expect(fixture.player.started, isFalse);
    expect(fixture.output.releaseCalls, 1);
    expect(fixture.player.disposed, isFalse);

    fixture.output.releaseReceipt.complete();
    expect((await shutdown).outcome, PlaybackShutdownOutcome.released);
    await fixture.runtime.released;
    expect(fixture.events, ['release-output', 'dispose-player']);
  });
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);

class _Runtime extends NativePlaybackRuntime {
  _Runtime({
    required super.player,
    required super.videoController,
    required super.subscribeToPlaybackEvents,
  }) : super.withResources(
         configuration: PlaybackRuntimeConfig(
           playerOptions: const {},
           hardwareAccelerationEnabled: false,
           hardwareDecoder: 'no',
         ),
         diagnosticsExtra: () => const {},
       );

  @override
  void sampleMediaClock() {}
}

class _Fixture {
  _Fixture({bool subscribeToPlaybackEvents = false}) {
    player = _Player(events, hasVideo: subscribeToPlaybackEvents);
    output = _Output(events);
    runtime = _Runtime(
      player: player,
      videoController: output,
      subscribeToPlaybackEvents: subscribeToPlaybackEvents,
    );
    recovery = PlaybackNetworkRecovery(
      delay: Duration.zero,
      isCurrent: () => true,
      readState: () => (
        buffering: player.state.buffering,
        position: player.state.position,
        buffer: player.state.buffer,
      ),
      reload: (_) async => reloads++,
      onError: (error) => fail('$error'),
      videoProgressing: () =>
          actual.playing != true ||
          actual.seeking == true ||
          actual.videoProgressing != false,
    );
    subscription = runtime.events.listen((event) {
      if (event is! PlaybackRuntimeStateChanged) return;
      actual = event.actual;
      if (actual.playing == true &&
          actual.seeking != true &&
          actual.videoProgressing == false) {
        recovery.schedule(
          allowNativeRecovery: false,
          requireVideoProgress: true,
          throttle: true,
        );
      }
    });
  }

  final events = <String>[];
  late final _Player player;
  late final _Output output;
  late final NativePlaybackRuntime runtime;
  late final PlaybackNetworkRecovery recovery;
  late final StreamSubscription<PlaybackRuntimeEvent> subscription;
  var actual = const PlaybackActual();
  var now = Duration.zero;
  var reloads = 0;

  Future<void> advance({
    bool consumeFrame = true,
    bool advancePosition = true,
    OutputOperationToken? frameToken,
  }) async {
    const interval = Duration(milliseconds: 250);
    now += interval;
    if (advancePosition) player.state.position += interval;
    player.emitProperty(
      'time-pos',
      '${player.state.position.inMilliseconds / 1000}',
    );
    player.emitProperty('audio-pts', '${now.inMilliseconds / 1000}');
    if (consumeFrame) {
      output.progress.add(
        VideoOutputProgress(
          token: frameToken ?? output.token!,
          consumedAtMonotonicUs: [now.inMicroseconds],
        ),
      );
    }
    await _turn();
  }

  Future<PlaybackRuntimeLoadResult> load() => runtime.load(
    PlaybackPlan(
      contentKey: 'shutdown-fixture',
      source: PlaybackSourceSnapshot.fromDataSource(
        NetworkSource(
          videoSource: 'https://example.test/live',
          audioSource: null,
        ),
      ),
      timeline: const PlaybackTimeline(
        kind: PlaybackTimelineKind.live,
        seekPolicy: PlaybackSeekPolicy.disabled,
      ),
      configuration: PlaybackConfiguration(audioOnly: !player.hasVideo),
    ),
    PlaybackExecutionContext(
      requestId: 1,
      runtimeId: runtime.runtimeId,
      loadId: 1,
      isCurrent: () => true,
      deadline: const Duration(seconds: 10),
      monotonicNow: () => now,
      cancelled: Completer<void>().future,
      registerCancellation: (_) {},
    ),
  );

  Future<void> close() async {
    recovery.dispose();
    await subscription.cancel();
    if (!output.releaseReceipt.isCompleted) output.releaseReceipt.complete();
    player.startFile();
    await player.unload();
    player.endFile();
    await runtime.shutdown();
    await player.events.close();
    await player.playback.playingEvents.close();
    for (final property in player.properties.values) {
      await property.close();
    }
    await output.progress.close();
  }
}

class _Player implements NativePlayer {
  _Player(this.calls, {this.hasVideo = false});
  final List<String> calls;
  final bool hasVideo;
  final playback = _PlayerStreams();
  final properties = <String, StreamController<String?>>{};
  @override
  PlayerStream get stream => playback;
  @override
  Stream<String?> observeProperty(String property) => properties
      .putIfAbsent(
        property,
        () => StreamController<String?>.broadcast(sync: true),
      )
      .stream;

  void emitProperty(String name, String value) => properties[name]?.add(value);

  void startPlaying() => setPlaying(true);

  void setPlaying(bool playing) {
    state.playing = playing;
    playback.playingEvents.add(playing);
  }

  final events = StreamController<NativePlayerEvent>.broadcast(sync: true);
  NativeLifecycleHookHandler? hook;
  bool stopTimesOut = false;
  bool openTimesOut = false;
  bool openFailsBeforeSubmission = false;
  bool started = false;
  @override
  bool disposed = false;
  @override
  final state = PlayerState();
  final releaseReceipt = Completer<void>();
  @override
  Future<void> get released => releaseReceipt.future;
  @override
  Stream<NativePlayerEvent> get nativeEvents => events.stream;
  @override
  NativeHookRegistration registerLifecycleHookHandler(
    NativeLifecycleHookHandler handler,
  ) {
    hook = handler;
    return NativeHookRegistration(() async => hook = null);
  }

  @override
  Future<void> open(
    Playable playable, {
    bool play = true,
    bool synchronized = true,
    void Function()? onLoadSubmitted,
  }) async {
    if (openFailsBeforeSubmission) throw TimeoutException('open stop reply');
    onLoadSubmitted?.call();
    if (openTimesOut) throw TimeoutException('open reply');
    startFile();
    events.add(
      NativeFileLoaded(
        playlistEntryId: 7,
        videoOutputParameters: hasVideo
            ? const NativeVideoOutputParameters(
                width: 640,
                height: 360,
                displayWidth: 640,
                displayHeight: 360,
                pixelAspectRatio: 1,
                rotation: 0,
              )
            : null,
        videoTracks: hasVideo
            ? const [
                NativeVideoTrackMetadata(
                  id: '1',
                  type: 'video',
                  demuxWidth: 640,
                  demuxHeight: 360,
                  demuxFps: 30,
                  demuxPar: 1,
                  demuxRotate: 0,
                  demuxCropKnownNone: true,
                  selected: true,
                ),
              ]
            : const [],
        hasAudio: true,
      ),
    );
    emitProperty('estimated-frame-number', '0');
  }

  void startFile() {
    if (started) return;
    started = true;
    events.add(const NativeStartFile(playlistEntryId: 7));
  }

  Future<void> unload() async {
    await hook?.call(
      const NativeHookRequest(
        hookId: 1,
        name: NativeHookName.onUnload,
        nativeHookName: 'on_unload',
        playlistEntryId: 7,
        teardown: true,
      ),
      _HookApi(),
    );
  }

  void endFile() {
    if (!events.isClosed) {
      events.add(
        const NativeEndFile(
          playlistEntryId: 7,
          reason: NativeEndFileReason.stop,
          error: 0,
        ),
      );
    }
  }

  @override
  Future<void> stop({bool open = false, bool synchronized = true}) async {
    calls.add('stop');
    if (stopTimesOut) throw TimeoutException('stop reply');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose-player');
    disposed = true;
    releaseReceipt.complete();
  }

  @override
  void setMediaHeader({
    String? userAgent,
    String? referer,
    Map<String, String>? headers,
  }) {}
  @override
  void setProperty(String property, String value) {}
  @override
  Future<void> setRate(double rate, {bool synchronized = true}) async {}
  @override
  Future<void> setVolume(double volume, {bool synchronized = true}) async {}
  @override
  Future<void> setAudioTrack(
    AudioTrack track, {
    bool synchronized = true,
  }) async {}
  @override
  Future<void> setSubtitleTrack(
    SubtitleTrack track, {
    bool synchronized = true,
  }) async {}
  @override
  Future<void> command(List<String> args, {int? seekObservationId}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected player call: ${invocation.memberName}');
}

class _Output implements VideoController {
  _Output(this.calls);
  final List<String> calls;
  final releaseReceipt = Completer<void>();
  int releaseCalls = 0;
  OutputOperationToken? token;
  final progress = StreamController<VideoOutputProgress>.broadcast(sync: true);
  @override
  Stream<VideoOutputProgress> get outputProgress => progress.stream;
  @override
  Stream<VideoFrameEvent> get frameEvents => const Stream.empty();
  @override
  bool get frameTimelineSupported => false;
  @override
  Future<VideoFrameSamplingState?> setVideoFrameSampling(
    OutputOperationToken token,
    bool enabled,
  ) async => null;
  @override
  Future<void>? setSize({int? width, int? height}) => null;

  OutputPreparationResult _prepared(OutputOperationToken token) =>
      OutputPreparationResult(
        strategy: OutputPreparationStrategy.prepared,
        evidence: OutputPreparationEvidence.nativeTextureAttachReceipt,
        outputEpoch: token.outputEpoch,
        geometry: const VideoOutputGeometry(width: 640, height: 360),
      );
  @override
  Future<OutputPreparationResult> confirmFileLoaded(
    OutputOperationToken token,
    NativeVideoOutputParameters? parameters, {
    required List<NativeVideoTrackMetadata>? videoTracks,
    required String? allowedTrackId,
  }) async => _prepared(token);
  @override
  Future<OutputPreparationResult> waitForOutputAttach(
    OutputOperationToken token,
  ) async => _prepared(token);
  @override
  Future<void> beginOutputForLoad(OutputOperationToken token) async {
    this.token = token;
  }

  @override
  Future<void> invalidateOutputGeneration(OutputOperationToken token) async =>
      calls.add('invalidate');
  @override
  Future<void> releaseOutput() async {
    releaseCalls++;
    calls.add('release-output');
    await releaseReceipt.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected output call: ${invocation.memberName}');
}

class _PlayerStreams implements PlayerStream {
  final playingEvents = StreamController<bool>.broadcast(sync: true);
  @override
  Stream<bool> get playing => playingEvents.stream;
  @override
  Stream<Duration> get position => const Stream.empty();
  @override
  Stream<Duration> get duration => const Stream.empty();
  @override
  Stream<bool> get completed => const Stream.empty();
  @override
  Stream<bool> get buffering => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected player stream: ${invocation.memberName}');
}

class _HookApi implements NativeHookApi {
  @override
  bool get isValid => true;
  @override
  List<NativeVideoTrackMetadata> readVideoTracks() => const [];
  @override
  void setOption(String name, String value) {}
}
