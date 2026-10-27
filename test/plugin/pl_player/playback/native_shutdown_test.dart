import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_playback_runtime.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDownAll(Diagnostics.instance.dispose);

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

class _Fixture {
  _Fixture() {
    player = _Player(events);
    output = _Output(events);
    runtime = NativePlaybackRuntime.withResources(
      configuration: PlaybackRuntimeConfig(
        playerOptions: const {},
        hardwareAccelerationEnabled: false,
        hardwareDecoder: 'no',
      ),
      diagnosticsExtra: () => const {},
      player: player,
      videoController: output,
    );
  }

  final events = <String>[];
  late final _Player player;
  late final _Output output;
  late final NativePlaybackRuntime runtime;
  final watch = Stopwatch()..start();

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
      configuration: PlaybackConfiguration(audioOnly: true),
    ),
    PlaybackExecutionContext(
      requestId: 1,
      runtimeId: runtime.runtimeId,
      loadId: 1,
      isCurrent: () => true,
      deadline: const Duration(seconds: 10),
      monotonicNow: () => watch.elapsed,
      cancelled: Completer<void>().future,
      registerCancellation: (_) {},
    ),
  );

  Future<void> close() async {
    if (!output.releaseReceipt.isCompleted) output.releaseReceipt.complete();
    player.startFile();
    await player.unload();
    player.endFile();
    await runtime.shutdown();
    await player.events.close();
  }
}

class _Player implements NativePlayer {
  _Player(this.calls);
  final List<String> calls;
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
        videoTracks: const [],
        hasAudio: true,
      ),
    );
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
  @override
  Future<void> beginOutputForLoad(OutputOperationToken token) async {}
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

class _HookApi implements NativeHookApi {
  @override
  bool get isValid => true;
  @override
  List<NativeVideoTrackMetadata> readVideoTracks() => const [];
  @override
  void setOption(String name, String value) {}
}
