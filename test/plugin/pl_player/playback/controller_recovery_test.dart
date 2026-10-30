import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/audio_recovery.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_playback_runtime.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/player_diagnostics.dart';
import 'package:pili_aurora/utils/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    GStorage.setting = await Hive.openBox('setting', bytes: Uint8List(0));
    GStorage.video = await Hive.openBox('video', bytes: Uint8List(0));
    GStorage.localCache = await Hive.openBox('cache', bytes: Uint8List(0));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/wakelock'),
          (_) async => null,
        );
  });
  tearDownAll(Hive.close);

  _recoveryTest('本地媒体手动重试保留暂停和续播位置', (f) async {
    await f.load(local: true, start: PlaybackStartPolicy.pause);
    f.runtime.player.state.position = const Duration(seconds: 42);
    await f.controller.refreshPlayer();
    expect(f.runtime.loads, hasLength(2));
    expect(f.runtime.loads.last.reloadPosition, const Duration(seconds: 42));
    expect(f.controller.wantsToPlay, isFalse);
  });

  _recoveryTest('视频故障优先切视频备用源，保留健康音轨', (f) async {
    await GStorage.setting.put('enableMultiCdn', true);
    try {
      await f.load(
        videoCandidates: const ['https://example.test/video-backup.mp4'],
        audioCandidates: const ['https://example.test/audio-backup.m4a'],
      );
      f.runtime.videoHealthy = false;
      await f.advance(3);
      final source = f.runtime.loads.last.source;
      expect(
        source.currentVideoSource,
        'https://example.test/video-backup.mp4',
      );
      expect(source.currentAudioSource, 'https://example.test/movie.m4a');
    } finally {
      await GStorage.setting.delete('enableMultiCdn');
    }
  });

  _recoveryTest('连续故障跨加载限频，手动重试可立即执行', (f) async {
    await f.load();
    f.runtime
      ..recoverOnLoad = false
      ..videoHealthy = false;
    await f.advance(3);
    expect(f.runtime.loads, hasLength(2));
    await f.advance(9);
    expect(f.runtime.loads, hasLength(2));
    await f.advance(1);
    expect(f.runtime.loads, hasLength(3));
    await f.controller.refreshPlayer();
    expect(f.runtime.loads, hasLength(4));
  });

  for (final mode in _Mode.values) {
    _recoveryTest('${mode.name}提前 EOF 从中断位置恢复，避免触发连播', (f) async {
      await f.load();
      f.runtime.complete(at: const Duration(seconds: 10));
      await f.tester.pump();
      expect(f.runtime.loads, hasLength(2));
      expect(f.runtime.loads.last.reloadPosition, const Duration(seconds: 10));
      expect(f.controller.wantsToPlay, isTrue);
      expect(f.controller.currentPlaybackSnapshot.pendingAction, isNull);
    }, mode: mode);

    _recoveryTest('${mode.name}断流后保留可播放缓存，耗尽后恢复一次并保留位置', (f) async {
      await f.load();
      f.readFailure();
      await f.advance(6);
      expect(f.runtime.loads, hasLength(1));
      expect(f.runtime.repairs, 0);

      f.runtime.player.state.buffer = f.runtime.player.state.position;
      f.runtime.setBuffering(true);
      await f.advance(3, advancing: false);
      expect(f.runtime.loads, hasLength(2));
      expect(f.runtime.loads.last.reloadPosition, const Duration(seconds: 16));
      expect(f.controller.wantsToPlay, isTrue);
    }, mode: mode);
  }

  _recoveryTest('原生重连补足已消耗缓存后取消整段重载', (f) async {
    await f.load();
    f.readFailure();
    await f.advance(6, refill: true);
    expect(f.runtime.loads, hasLength(1));
    expect(f.runtime.repairs, 0);
    expect(f.controller.audioRecoveryStatus.value, AudioRecoveryStatus.idle);
  });

  for (final bufferingFirst in [true, false]) {
    _recoveryTest('跳转${bufferingFirst ? '先缓冲' : '先停帧'}，画面恢复后不重载', (f) async {
      await f.load();
      if (bufferingFirst) f.runtime.setBuffering(true);
      f.runtime
        ..seeking = true
        ..videoHealthy = false;
      f.runtime.player.state.position = const Duration(seconds: 60);
      f.runtime.setBuffering(false);
      f.runtime.seeking = false;
      f.runtime.emitActual();
      if (!bufferingFirst) {
        f.runtime
          ..setBuffering(true)
          ..setBuffering(false);
      }
      await f.tester.pump();
      expect(f.controller.isVideoStalled.value, isTrue);

      f.runtime.videoHealthy = true;
      await f.advance(3);
      expect(f.controller.isVideoStalled.value, isFalse);
      expect(f.runtime.loads, hasLength(1));
    });
  }

  _recoveryTest('断流与短暂停帧合并后，画面恢复仍保留缓存耗尽时的恢复机会', (f) async {
    await f.load();
    f.readFailure();
    f.runtime.videoHealthy = false;
    f.runtime.emitActual();
    await f.tester.pump();
    f.runtime.videoHealthy = true;
    await f.advance(3);
    expect(f.runtime.loads, hasLength(1));

    f.runtime.player.state.buffer = f.runtime.player.state.position;
    f.runtime.setBuffering(true);
    await f.advance(3, advancing: false);
    expect(f.runtime.loads, hasLength(2));
  });

  _recoveryTest('缓冲标志置位但缓存仍推进时不误判画面故障，持续停滞后再恢复', (f) async {
    await f.load();
    f.readFailure();
    f.runtime.setBuffering(true);
    for (var i = 0; i < 3; i++) {
      f.runtime.player.state.position += const Duration(seconds: 1);
      f.runtime.emitActual();
      await f.tester.pump(const Duration(seconds: 1));
    }
    expect(f.runtime.loads, hasLength(1));
    await f.advance(3, advancing: false);
    expect(f.runtime.loads, hasLength(2));
  });

  _recoveryTest('只听音频时主时钟停止且没有新错误或缓冲事件，仍恢复已确认的音频停滞', (f) async {
    await f.load();
    f.runtime.audioHealthy = false;
    f.runtime.onRepair = () async =>
        const PlaybackRuntimeCommandResult(applied: false);
    await f.advance(3, advancing: false);
    expect(f.runtime.repairs, 1);
    expect(f.runtime.loads, hasLength(2));
    expect(f.runtime.loads.last.reloadPosition, const Duration(seconds: 10));
  }, mode: _Mode.audioOnly);

  _recoveryTest('音轨耗尽而画面正常，独立修复音轨并验证恢复，不重载画面', (f) async {
    await f.load();
    f.readFailure();
    await f.advance(4);
    f.runtime.audioHealthy = false;
    await f.advance(2);
    expect(f.runtime.repairs, 1);
    expect(f.runtime.loads, hasLength(1));
    f.runtime.audioHealthy = true;
    await f.advance(10, refill: true);
    expect(f.runtime.loads, hasLength(1));
    expect(f.controller.audioRecoveryStatus.value, AudioRecoveryStatus.idle);
  });

  for (final readFailureFirst in [true, false]) {
    _recoveryTest(
      '画面停滞不被另一轨缓存掩盖，${readFailureFirst ? '先收到断流' : '先收到停帧'}仍恢复一次',
      (f) async {
        await f.load();
        if (readFailureFirst) f.readFailure();
        f.runtime.videoHealthy = false;
        f.runtime.emitActual();
        await f.tester.pump();
        if (!readFailureFirst) f.readFailure();
        await f.advance(3);
        expect(f.runtime.loads, hasLength(2));
        expect(f.runtime.repairs, 0);
      },
    );
  }

  _recoveryTest('双轨同时耗尽且音轨命令在途，整段恢复合并并隔离旧回执', (f) async {
    await f.load();
    final pending = Completer<PlaybackRuntimeCommandResult>();
    f.runtime.onRepair = () => pending.future;
    f.runtime.audioHealthy = false;
    f.runtime.emitActual();
    await f.advance(2);
    expect(f.runtime.repairs, 1);
    f.readFailure();
    f.runtime.videoHealthy = false;
    f.runtime.player.state.buffer = f.runtime.player.state.position;
    f.runtime.setBuffering(true);
    await f.advance(3, advancing: false);
    pending.complete(const PlaybackRuntimeCommandResult(applied: false));
    await f.tester.pump();
    await f.advance(12, refill: true);
    expect(f.runtime.loads, hasLength(2));
    expect(f.runtime.repairs, 1);
  });

  _recoveryTest('未请求播放时，断流不能自动播放；手动开始后健康缓存继续播放', (f) async {
    await f.load(start: PlaybackStartPolicy.pause);
    f.readFailure();
    await f.advance(6, advancing: false);
    expect(f.runtime.loads, hasLength(1));
    expect(f.controller.wantsToPlay, isFalse);
    await f.owner.setPlaying(true);
    await f.advance(12, refill: true);
    expect(f.runtime.loads, hasLength(1));
    expect(f.controller.wantsToPlay, isTrue);
  });

  _recoveryTest('重试排队后暂停，恢复播放时两轨已健康则不重载', (f) async {
    await f.load();
    f.readFailure();
    f.runtime.player.state.buffer = f.runtime.player.state.position;
    await f.owner.setPlaying(false);
    await f.advance(60, advancing: false);
    expect(f.runtime.loads, hasLength(1));
    expect(f.controller.wantsToPlay, isFalse);
    await f.owner.setPlaying(true);
    await f.advance(12, refill: true);
    expect(f.runtime.loads, hasLength(1));
  });

  _recoveryTest('跳转期间不提交断流重载，跳转结束仍故障时继续恢复', (f) async {
    await f.load();
    f.readFailure();
    f.runtime.seeking = true;
    f.runtime.player.state
      ..position = const Duration(seconds: 40)
      ..buffer = const Duration(seconds: 40);
    f.runtime.setBuffering(true);
    await f.advance(3, advancing: false);
    expect(f.runtime.loads, hasLength(1));
    f.runtime.seeking = false;
    f.runtime.emitActual();
    await f.advance(3, advancing: false);
    expect(f.runtime.loads, hasLength(2));
    expect(f.runtime.loads.last.reloadPosition, const Duration(seconds: 40));
  });

  _recoveryTest('已排队的画面恢复在切换只听音频后取消', (f) async {
    await f.load();
    f.runtime.videoHealthy = false;
    f.runtime.emitActual();
    await f.tester.pump();
    await f.controller.setOnlyAudio(true);
    await f.advance(6);
    expect(f.runtime.loads, hasLength(1));
    expect(f.controller.onlyPlayAudio.value, isTrue);
    expect(f.controller.isVideoStalled.value, isFalse);
  });

  _recoveryTest('跳转期间提前 EOF 延后恢复，跳转结束仍故障时再重载', (f) async {
    await f.load();
    f.runtime
      ..seeking = true
      ..videoHealthy = false;
    f.runtime.emitActual();
    f.runtime.complete(at: const Duration(seconds: 10));
    await f.tester.pump();
    expect(f.runtime.loads, hasLength(1));
    expect(f.controller.wantsToPlay, isTrue);
    f.runtime.seeking = false;
    f.runtime.emitActual();
    await f.tester.pump();
    expect(f.runtime.loads, hasLength(2));
    expect(f.runtime.loads.last.reloadPosition, const Duration(seconds: 10));
  });

  _recoveryTest('静音期间不修复音轨，取消静音后恢复遗留故障', (f) async {
    await f.load();
    await f.controller.setMuted(true);
    f.runtime.audioHealthy = false;
    f.audioError();
    await f.advance(12);
    expect(f.runtime.repairs, 0);
    expect(f.runtime.loads, hasLength(1));
    await f.controller.setMuted(false);
    await f.advance(2);
    expect(f.runtime.repairs, 1);
    f.runtime.audioHealthy = true;
    await f.advance(10);
    expect(f.runtime.loads, hasLength(1));
    expect(f.controller.audioRecoveryStatus.value, AudioRecoveryStatus.idle);
  });

  _recoveryTest('静音时画面故障仍恢复；只听音频加静音时不检测画面', (f) async {
    await f.load();
    await f.controller.setMuted(true);
    f.runtime.videoHealthy = false;
    f.runtime.emitActual();
    await f.advance(3);
    expect(f.runtime.loads, hasLength(2));
    expect(f.runtime.loads.last.configuration.volume, 0);
    await f.controller.setOnlyAudio(true);
    f.runtime.videoHealthy = false;
    f.runtime.audioHealthy = false;
    f.runtime.emitActual();
    await f.advance(6);
    expect(f.runtime.loads, hasLength(2));
    expect(f.runtime.repairs, 0);
  });

  _recoveryTest('音量为零时让出音轨恢复，调高音量后继续确认故障', (f) async {
    await f.load();
    await f.controller.setVolume(0, showIndicator: false);
    expect(f.controller.isMuted, isFalse);
    f.runtime.audioHealthy = false;
    f.audioError();
    await f.advance(12);
    expect(f.runtime.repairs, 0);
    await f.controller.setVolume(.5, showIndicator: false);
    await f.advance(2);
    expect(f.runtime.repairs, 1);
    f.runtime.audioHealthy = true;
    await f.advance(10);
    expect(f.runtime.loads, hasLength(1));
  });

  _recoveryTest('完成事件取消已排队的网络和音频恢复', (f) async {
    await f.load();
    f.readFailure();
    f.runtime.audioHealthy = false;
    f.audioError();
    f.runtime.complete();
    await f.advance(12, advancing: false);
    expect(f.runtime.loads, hasLength(1));
    expect(f.runtime.repairs, 0);
    expect(f.controller.currentPlaybackSnapshot.phase, PlaybackPhase.ended);
    expect(f.controller.wantsToPlay, isFalse);
  });

  _recoveryTest('切源后旧音轨回执和旧网络计时器不能重开新媒体', (f) async {
    await f.load();
    final pending = Completer<PlaybackRuntimeCommandResult>();
    f.runtime.onRepair = () => pending.future;
    f.runtime.audioHealthy = false;
    f.audioError();
    await f.advance(2);
    f.readFailure();
    final switching = f.load(key: 'next');
    await f.tester.pump();
    pending.complete(const PlaybackRuntimeCommandResult(applied: false));
    await switching;
    await f.advance(12, refill: true);
    expect(f.runtime.loads.map((plan) => plan.contentKey), ['movie', 'next']);
    expect(f.runtime.repairs, 1);
  });

  _recoveryTest('播放完成后迟到的音轨失败回执不能重载或自动播放', (f) async {
    await f.load();
    final pending = Completer<PlaybackRuntimeCommandResult>();
    f.runtime.onRepair = () => pending.future;
    f.runtime.audioHealthy = false;
    f.audioError();
    await f.advance(2);
    expect(f.runtime.repairs, 1);
    f.runtime.complete();
    pending.complete(const PlaybackRuntimeCommandResult(applied: false));
    await f.advance(12, advancing: false);
    expect(f.runtime.loads, hasLength(1));
    expect(f.controller.wantsToPlay, isFalse);
  });

  _recoveryTest('关闭时取消两条恢复通路，迟到回执不能重载', (f) async {
    await f.load();
    final pending = Completer<PlaybackRuntimeCommandResult>();
    f.runtime.onRepair = () => pending.future;
    f.runtime.audioHealthy = false;
    f.audioError();
    await f.advance(2);
    f.readFailure();
    await f.controller.shutdownPlaybackFacade();
    pending.complete(const PlaybackRuntimeCommandResult(applied: false));
    await f.advance(12, advancing: false);
    expect(f.runtime.loads, hasLength(1));
    expect(f.controller.currentPlaybackSnapshot.phase, PlaybackPhase.disposed);
  });

  _recoveryTest('持续画面故障跨重载最多自动恢复三次，不无限加载', (f) async {
    await f.load();
    f.runtime
      ..recoverOnLoad = false
      ..videoHealthy = false;
    await f.advance(3);
    expect(f.runtime.loads, hasLength(2));
    await f.advance(9);
    expect(f.runtime.loads, hasLength(2));
    await f.advance(1);
    expect(f.runtime.loads, hasLength(3));
    await f.advance(14);
    expect(f.runtime.loads, hasLength(3));
    await f.advance(1);
    expect(f.runtime.loads, hasLength(4));
    await f.advance(5);
    expect(f.runtime.loads, hasLength(4));
    expect(f.controller.currentPlaybackSnapshot.phase, PlaybackPhase.failed);
    expect(
      f.controller.currentPlaybackSnapshot.failure?.operation,
      'automatic-recovery',
    );
  });

  _recoveryTest('权限失败终止两条恢复通路，重复日志不能轮换来源', (f) async {
    await f.load();
    f.readFailure();
    f.runtime.audioHealthy = false;
    f.audioError();
    f.runtime.player.playback.logs.add(
      const PlayerLog(
        prefix: 'ffmpeg',
        level: 'error',
        text: 'HTTP error 403 Forbidden',
      ),
    );
    await f.advance(1);
    f
      ..readFailure()
      ..audioError();
    await f.advance(12, advancing: false);
    expect(f.runtime.loads, hasLength(1));
    expect(f.runtime.repairs, 0);
  });

  _recoveryTest('限频等待中的重载在权限失败后取消', (f) async {
    await f.load();
    f.runtime
      ..recoverOnLoad = false
      ..videoHealthy = false;
    await f.advance(6);
    expect(f.runtime.loads, hasLength(2));
    f.runtime.player.playback.logs.add(
      const PlayerLog(
        prefix: 'ffmpeg',
        level: 'error',
        text: 'HTTP error 403 Forbidden',
      ),
    );
    await f.advance(12);
    expect(f.runtime.loads, hasLength(2));
  });

  _recoveryTest('提前 EOF 在限频期保持停止，到期后从中断位置恢复', (f) async {
    await f.load();
    f.runtime.complete(at: const Duration(seconds: 1));
    await f.tester.pump();
    expect(f.runtime.loads, hasLength(2));
    f.runtime.complete(at: const Duration(seconds: 2));
    await f.tester.pump();
    await f.advance(9, advancing: false);
    expect(f.runtime.loads, hasLength(2));
    expect(f.runtime.player.state.playing, isFalse);
    await f.advance(1, advancing: false);
    expect(f.runtime.loads, hasLength(3));
    expect(f.runtime.loads.last.reloadPosition, const Duration(seconds: 2));
    expect(f.controller.wantsToPlay, isTrue);
  });

  _recoveryTest('限频等待期间恢复画面，取消遗留的整段重载', (f) async {
    await f.load();
    f.runtime
      ..recoverOnLoad = false
      ..videoHealthy = false;
    await f.advance(6);
    expect(f.runtime.loads, hasLength(2));
    f.runtime.videoHealthy = true;
    await f.advance(15);
    expect(f.runtime.loads, hasLength(2));
    expect(f.controller.isVideoStalled.value, isFalse);
  });

  _recoveryTest('本地文件不进入网络与外部音轨重连', (f) async {
    await f.load(local: true);
    f.runtime.videoHealthy = false;
    f.runtime.audioHealthy = false;
    f
      ..readFailure()
      ..audioError();
    await f.advance(12);
    expect(f.runtime.loads, hasLength(1));
    expect(f.runtime.repairs, 0);
  });
}

void _recoveryTest(
  String name,
  Future<void> Function(_Fixture) body, {
  _Mode mode = _Mode.separate,
}) {
  testWidgets(name, (tester) async {
    final f = _Fixture(tester, mode: mode);
    try {
      await body(f);
    } finally {
      await f.dispose();
    }
  });
}

enum _Mode { separate, combined, audioOnly, videoOnly }

// 使用真实控制器、Session 与两个恢复器；替换原生 I/O 和轨道健康输入。
class _Fixture {
  _Fixture(this.tester, {this.mode = _Mode.separate}) {
    controller = PlPlayerController.withRuntime(
      runtime,
      monotonicNow: () => Duration(
        microseconds: tester.binding.clock.now().microsecondsSinceEpoch,
      ),
    )..enableHeart = false;
    owner = controller.attachPlaybackOwner();
  }

  Future<void> dispose() async {
    await controller.shutdownPlaybackFacade();
    await tester.pump();
    await runtime.closeStreams();
  }

  final WidgetTester tester;
  final _Mode mode;
  final runtime = _Runtime();
  late final PlPlayerController controller;
  late final PlaybackOwner owner;

  Future<void> load({
    String key = 'movie',
    PlaybackStartPolicy start = PlaybackStartPolicy.play,
    bool local = false,
    List<String> videoCandidates = const [],
    List<String> audioCandidates = const [],
  }) async {
    runtime.hasVideo = mode != _Mode.audioOnly;
    runtime.hasAudio = mode != _Mode.videoOnly;
    final plan = PlaybackPlan(
      contentKey: key,
      source: PlaybackSourceSnapshot.fromDataSource(
        local
            ? FileSource(
                dir: 'E:/offline',
                isMp4: true,
                hasDashAudio: false,
                typeTag: 'test',
              )
            : NetworkSource(
                videoSource: 'https://example.test/$key.mp4',
                videoCandidates: videoCandidates,
                audioCandidates: audioCandidates,
                audioSource: mode == _Mode.separate
                    ? 'https://example.test/$key.m4a'
                    : null,
              ),
      ),
      timeline: const PlaybackTimeline(
        kind: PlaybackTimelineKind.onDemand,
        seekPolicy: PlaybackSeekPolicy.allowed,
        duration: Duration(minutes: 5),
      ),
      configuration: PlaybackConfiguration(audioOnly: mode == _Mode.audioOnly),
    );
    final result = await controller.loadPlaybackPlan(
      owner: owner,
      plan: plan,
      start: start,
      live: false,
    );
    expect(result.outcome, LoadOutcome.ready);
    await tester.pump();
  }

  void readFailure() => runtime.player.playback.logs.add(
    const PlayerLog(
      prefix: 'curl',
      level: 'error',
      text: 'transfer failed: Failure when receiving data from the peer',
    ),
  );
  void audioError() => runtime.player.playback.logs.add(
    const PlayerLog(
      prefix: 'ad',
      level: 'error',
      text: 'Error decoding audio.',
    ),
  );

  Future<void> advance(
    int seconds, {
    bool advancing = true,
    bool refill = false,
  }) async {
    for (var i = 0; i < seconds; i++) {
      final state = runtime.player.state;
      if (advancing && state.playing && !state.buffering && !runtime.seeking) {
        state.position += const Duration(seconds: 1);
        if (refill) state.buffer += const Duration(seconds: 1);
        if (runtime.audioHealthy) {
          runtime.diagnostic.properties['audio-pts'] =
              '${state.position.inMicroseconds / 1000000}';
        }
      }
      runtime.emitActual();
      await tester.pump(const Duration(seconds: 1));
    }
  }
}

class _Runtime extends NativePlaybackRuntime {
  _Runtime()
    : super(
        configuration: PlaybackRuntimeConfig(
          playerOptions: const {},
          hardwareAccelerationEnabled: false,
          hardwareDecoder: 'no',
        ),
        diagnosticsExtra: () => const {},
      );

  @override
  final _Player player = _Player();
  final diagnostic = _Diagnostics();
  @override
  PlayerDiagnostics get diagnostics => diagnostic;
  final _events = StreamController<PlaybackRuntimeEvent>.broadcast(sync: true);
  final _released = Completer<void>();
  @override
  Stream<PlaybackRuntimeEvent> get events => _events.stream;
  @override
  Future<void> get released => _released.future;
  @override
  Duration get position => player.state.position;
  final loads = <PlaybackPlan>[];
  bool hasVideo = true;
  bool hasAudio = true;
  bool videoHealthy = true;
  bool audioHealthy = true;
  bool recoverOnLoad = true;
  bool seeking = false;
  int loadId = 0;
  int repairs = 0;
  Future<PlaybackRuntimeCommandResult> Function()? onRepair;

  void emitActual() {
    final progressing =
        player.state.playing && !player.state.buffering && !seeking;
    _events.add(
      PlaybackRuntimeStateChanged(
        runtimeId: runtimeId,
        loadId: loadId,
        actual: PlaybackActual(
          playing: player.state.playing,
          buffering: player.state.buffering,
          seeking: seeking,
          position: position,
          duration: player.state.duration,
          videoProgressing: videoHealthy && progressing,
          audioProgressing: audioHealthy && progressing,
        ),
      ),
    );
  }

  void setBuffering(bool value) {
    player.state.buffering = value;
    emitActual();
    player.playback.bufferingEvents.add(value);
  }

  void complete({Duration? at}) {
    player.state.position = at ?? player.state.duration;
    player.state
      ..completed = true
      ..playing = false;
    emitActual();
    _events.add(PlaybackRuntimeEnded(runtimeId: runtimeId, loadId: loadId));
    player.playback.completedEvents.add(true);
  }

  @override
  Future<PlaybackRuntimeLoadResult> load(
    PlaybackPlan plan,
    PlaybackExecutionContext context,
  ) async {
    loads.add(plan);
    loadId = context.loadId;
    player.state
      ..completed = false
      ..buffering = false
      ..position =
          plan.reloadPosition ??
          plan.startPosition ??
          const Duration(seconds: 10)
      ..duration = const Duration(minutes: 5)
      ..buffer = const Duration(seconds: 90)
      ..tracks = Tracks(
        audio: hasAudio ? const [AudioTrack('1', null, null)] : const [],
      );
    player.current
      ..clear()
      ..add(Media(plan.source.currentVideoSource));
    if (recoverOnLoad) videoHealthy = audioHealthy = true;
    seeking = false;
    diagnostic.properties['audio-pts'] = '${position.inMicroseconds / 1000000}';
    return PlaybackRuntimeLoadResult(
      loaded: true,
      output: PlaybackOutputPreparation(
        strategy: hasVideo
            ? PlaybackOutputStrategy.prepared
            : PlaybackOutputStrategy.noVideo,
        evidence: 'test-native-output',
        outputEpoch: loadId,
        hasVideo: hasVideo,
      ),
      capabilities: PlaybackCapabilities(
        hasVideo: hasVideo,
        hasAudio: hasAudio,
        seekSupport: PlaybackSeekSupport.supported,
        seekStart: Duration.zero,
        seekEnd: player.state.duration,
      ),
    );
  }

  @override
  void sampleMediaClock() {}

  @override
  Future<PlaybackRuntimeCommandResult> setPlaying(
    bool value,
    PlaybackExecutionContext context,
  ) async {
    if (!context.isCurrent()) {
      return const PlaybackRuntimeCommandResult(applied: false);
    }
    player.state.playing = value;
    emitActual();
    player.playback.playingEvents.add(value);
    return const PlaybackRuntimeCommandResult();
  }

  @override
  Future<PlaybackRuntimeCommandResult> reloadAudio(
    PlaybackExecutionContext context,
  ) async {
    repairs++;
    return onRepair?.call() ?? const PlaybackRuntimeCommandResult();
  }

  @override
  Future<PlaybackRuntimeCommandResult> setAudioOnly(
    bool value,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();
  @override
  Future<PlaybackRuntimeCommandResult> setVolume(
    double value,
    PlaybackExecutionContext context,
  ) async {
    player.state.volume = value;
    return const PlaybackRuntimeCommandResult();
  }

  @override
  Future<PlaybackShutdownResult> shutdown() async {
    if (!_released.isCompleted) _released.complete();
    return const PlaybackShutdownResult.released();
  }

  Future<void> closeStreams() async {
    await _events.close();
    await player.playback.logs.close();
    await player.playback.playingEvents.close();
    await player.playback.bufferingEvents.close();
    await player.playback.completedEvents.close();
  }
}

class _Diagnostics implements PlayerDiagnostics {
  final properties = <String, String>{};
  @override
  String? property(String name) => properties[name];
  @override
  void event(
    String action, {
    DiagnosticLogLevel level = DiagnosticLogLevel.info,
    Map<String, Object?>? details,
  }) {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected diagnostics: ${invocation.memberName}');
}

class _Player implements NativePlayer {
  @override
  final state = PlayerState();
  final playback = _Streams();
  @override
  PlayerStream get stream => playback;
  @override
  final current = <Media>[];
  @override
  bool disposed = false;
  @override
  Stream<String?> observeProperty(String property) => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected player: ${invocation.memberName}');
}

class _Streams implements PlayerStream {
  final logs = StreamController<PlayerLog>.broadcast(sync: true);
  final playingEvents = StreamController<bool>.broadcast(sync: true);
  final bufferingEvents = StreamController<bool>.broadcast(sync: true);
  final completedEvents = StreamController<bool>.broadcast(sync: true);
  @override
  Stream<PlayerLog> get log => logs.stream;
  @override
  Stream<bool> get playing => playingEvents.stream;
  @override
  Stream<bool> get buffering => bufferingEvents.stream;
  @override
  Stream<bool> get completed => completedEvents.stream;
  @override
  Stream<Duration> get position => const Stream.empty();
  @override
  Stream<Duration> get duration => const Stream.empty();
  @override
  Stream<Duration> get buffer => const Stream.empty();
  @override
  Stream<VideoParams> get videoParams => const Stream.empty();
  @override
  Stream<String> get error => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected player stream: ${invocation.memberName}');
}
