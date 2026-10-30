import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/playback/audio_recovery.dart';

void main() {
  late _Playback playback;
  late PlaybackAudioRecovery recovery;
  late int repairs;
  late int reloads;
  late int notices;
  late int now;
  late List<Object> errors;
  late List<String> diagnostics;
  late List<AudioRecoveryStatus> statuses;

  setUp(() {
    playback = _Playback();
    repairs = reloads = notices = now = 0;
    errors = [];
    diagnostics = [];
    statuses = [];
    recovery = PlaybackAudioRecovery(
      readState: () => playback.attached ? playback.state : null,
      repairAudio: () async {
        repairs++;
        return true;
      },
      reload: () async => reloads++,
      onError: errors.add,
      onDiagnostic: diagnostics.add,
      onStatusChanged: statuses.add,
      onExhausted: () => notices++,
      elapsedMilliseconds: () => now,
    );
  });
  tearDown(() => recovery.dispose());

  void audioError() => recovery.onLog(
    prefix: 'ad',
    level: 'error',
    message: 'Error decoding audio.',
  );
  Future<void> tick(WidgetTester tester, {bool healthy = false}) async {
    now += 2000;
    playback.position += const Duration(seconds: 2);
    if (healthy) playback.audioPts = playback.position.inSeconds.toDouble();
    await tester.pump(const Duration(seconds: 2));
  }

  Future<void> verifyRecovery(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tick(tester);
    }
  }

  testWidgets('音轨命令返回后等待时钟恢复，短暂空窗不重载视频', (tester) async {
    playback.audioPts = null;
    audioError();
    await tick(tester);
    expect(repairs, 1);
    expect(statuses.last, AudioRecoveryStatus.recovering);
    expect(diagnostics, contains('audio.recovery.track.accepted'));
    expect(diagnostics, isNot(contains('audio.recovery.verified')));
    for (var i = 0; i < 3; i++) {
      await tick(tester);
      expect(reloads, 0);
    }
    await tick(tester, healthy: true);
    expect(reloads, 0);
    expect(diagnostics, contains('audio.recovery.verified'));
    expect(statuses.last, AudioRecoveryStatus.idle);
    recovery.dispose();
  });

  testWidgets('恢复观察按有效播放计时，暂停缓冲和拖动不消耗预算', (tester) async {
    playback.audioPts = null;
    audioError();
    await tick(tester);
    await tick(tester);
    for (final waiting in [false, true]) {
      playback
        ..playing = waiting
        ..waiting = waiting;
      recovery.onPlaybackChanged();
      now += 60000;
      await tester.pump(const Duration(minutes: 1));
      playback
        ..playing = true
        ..waiting = false;
      recovery.onPlaybackChanged();
      await tick(tester);
      expect(reloads, 0);
    }
    await tick(tester);
    expect(reloads, 1);
    expect(notices, 0);
    await verifyRecovery(tester);
    expect(notices, 1);
    recovery.dispose();
  });

  testWidgets('重复日志不延长音轨恢复观察，失败后按预算升级', (tester) async {
    playback.audioPts = null;
    audioError();
    await tick(tester);
    for (var i = 0; i < 3; i++) {
      audioError();
      await tick(tester);
      expect(reloads, 0);
    }
    audioError();
    await tick(tester);
    expect(repairs, 1);
    expect(reloads, 1);
    recovery.dispose();
  });

  testWidgets('没有新错误日志时，原生音频停滞信号仍能启动恢复', (tester) async {
    playback.audioPts = null;
    recovery.observe();
    await tick(tester);
    expect(repairs, 1);
    expect(statuses.last, AudioRecoveryStatus.recovering);
    recovery.dispose();
  });

  testWidgets('网络截断后继续消耗音频缓存，保持画面和声音', (tester) async {
    recovery.onLog(
      prefix: 'ffmpeg/demuxer',
      level: 'error',
      message:
          'mov,mp4,m4a,3gp,3g2,mj2: stream 0, offset 0xeb17ab: partial file',
    );
    for (var i = 0; i < 6; i++) {
      await tick(tester, healthy: true);
    }
    expect(repairs, 0);
    // 音频缓存耗尽后，视频继续前进仍会触发音轨重连。
    await tick(tester);
    expect(repairs, 1);
    expect(reloads, 0);
    expect(notices, 0);
    recovery.dispose();
  });

  testWidgets('curl读取终止后缓存可播放超过30秒，耗尽及缓存内跳转仍恢复音轨', (tester) async {
    recovery.onLog(
      prefix: 'curl',
      level: 'error',
      message: 'transfer failed: Failure when receiving data from the peer',
    );
    for (var i = 0; i < 25; i++) {
      await tick(tester, healthy: true);
    }
    expect(repairs, 0);
    expect(reloads, 0);
    // 视频缓存继续播放；音频时间停住，缓存内向右跳转也未产生新的错误。
    playback.position += const Duration(seconds: 3);
    recovery.onPlaybackChanged();
    await tick(tester);
    expect(repairs, 1);
    await verifyRecovery(tester);
    expect(reloads, 1);
    recovery.dispose();
  });

  testWidgets('单个损坏音频包后解码恢复，取消侵入式兜底', (tester) async {
    audioError();
    for (var i = 0; i < 16; i++) {
      await tick(tester, healthy: true);
    }
    expect(repairs, 0);
    expect(reloads, 0);
    recovery.dispose();
  });

  testWidgets('音轨重连后持续健康，后续断流可以再次恢复', (tester) async {
    void readFailure() => recovery.onLog(
      prefix: 'curl',
      level: 'error',
      message: 'transfer failed: Failure when receiving data from the peer',
    );
    playback.audioPts = null;
    readFailure();
    await tick(tester);
    expect(repairs, 1);
    for (var i = 0; i < 16; i++) {
      await tick(tester, healthy: true);
    }
    expect(reloads, 0);
    playback.audioPts = null;
    readFailure();
    await tick(tester);
    expect(repairs, 2);
    expect(reloads, 0);
    recovery.dispose();
  });

  testWidgets('重连回执前再次断流，残余缓存不能清除新故障', (tester) async {
    recovery.dispose();
    final pending = Completer<bool>();
    recovery = PlaybackAudioRecovery(
      readState: () => playback.state,
      repairAudio: () {
        repairs++;
        return pending.future;
      },
      reload: () async => reloads++,
      onError: errors.add,
      elapsedMilliseconds: () => now,
    );
    void readFailure() => recovery.onLog(
      prefix: 'curl',
      level: 'error',
      message: 'transfer failed: Failed sending data to the peer',
    );
    playback.audioPts = null;
    readFailure();
    await tick(tester);
    expect(repairs, 1);
    readFailure();
    pending.complete(true);
    for (var i = 0; i < 25; i++) {
      await tick(tester, healthy: true);
    }
    expect(reloads, 0);
    await tick(tester);
    expect(repairs, 1);
    expect(reloads, 1);
    recovery.dispose();
  });

  testWidgets('音频解码失败先修音轨，恢复后持续播放', (tester) async {
    playback.audioPts = null;
    audioError();
    await tick(tester);
    expect(repairs, 1);
    for (var i = 0; i < 16; i++) {
      await tick(tester, healthy: true);
    }
    expect(reloads, 0);
    expect(notices, 0);
    // 连续健康 30 秒后，新故障重新获得轻量恢复预算。
    playback.audioPts = null;
    audioError();
    await tick(tester);
    expect(repairs, 2);
    recovery.dispose();
  });

  testWidgets('音轨重连无效再重载，错误风暴不能反复重开视频', (tester) async {
    playback.audioPts = null;
    for (var i = 0; i < 20; i++) {
      audioError();
    }
    await tick(tester);
    expect(repairs, 1);
    audioError();
    await verifyRecovery(tester);
    expect(reloads, 1);
    await verifyRecovery(tester);
    expect(notices, 1);
    for (var i = 0; i < 20; i++) {
      audioError();
      await tick(tester);
    }
    expect(repairs, 1);
    expect(reloads, 1);
    expect(notices, 1);
    recovery.dispose();
  });

  testWidgets('暂停或拖动期间让路，恢复播放后再检查遗留失声', (tester) async {
    playback.audioPts = null;
    audioError();
    playback.playing = false;
    recovery.onPlaybackChanged();
    await tick(tester);
    expect(repairs, 0);
    playback
      ..playing = true
      ..waiting = true;
    recovery.onPlaybackChanged();
    await tick(tester);
    expect(repairs, 0);
    playback.waiting = false;
    recovery.onPlaybackChanged();
    await tick(tester);
    expect(repairs, 1);
    expect(reloads, 0);
    recovery.dispose();
  });

  testWidgets('接近片尾和停止前进的媒体不触发重载', (tester) async {
    playback
      ..duration = const Duration(seconds: 12)
      ..audioPts = null;
    audioError();
    await tick(tester);
    expect(repairs, 0);
    playback.duration = const Duration(seconds: 300);
    recovery
      ..reset()
      ..onLog(
        prefix: 'ffmpeg/demuxer',
        level: 'error',
        message: 'mov,mp4: partial file',
      )
      ..onPlaybackChanged();
    await tester.pump(const Duration(seconds: 2));
    expect(repairs, 0);
    recovery.dispose();
  });

  testWidgets('加载忙时保留预算，音轨命令失败后再升级', (tester) async {
    recovery.dispose();
    var busy = true;
    recovery = PlaybackAudioRecovery(
      readState: () => playback.state,
      repairAudio: () {
        if (busy) return null;
        repairs++;
        return Future.error(StateError('audio reload rejected'));
      },
      reload: () async => reloads++,
      onError: errors.add,
      elapsedMilliseconds: () => now,
    );
    playback.audioPts = null;
    audioError();
    await tick(tester);
    expect(repairs, 0);
    busy = false;
    await tick(tester);
    expect(repairs, 1);
    expect(errors, hasLength(1));
    await tick(tester);
    expect(reloads, 1);
    recovery.dispose();
  });

  testWidgets('切源或关闭后，旧音轨重连收尾不能重开媒体', (tester) async {
    recovery.dispose();
    final pending = Completer<bool>();
    recovery = PlaybackAudioRecovery(
      readState: () => playback.attached ? playback.state : null,
      repairAudio: () => pending.future,
      reload: () async => reloads++,
      onError: errors.add,
    );
    playback.audioPts = null;
    audioError();
    await tick(tester);
    recovery.reset();
    playback.attached = false;
    pending.complete(false);
    await tick(tester);
    expect(reloads, 0);
    recovery.dispose();
    audioError();
    await tick(tester);
    expect(reloads, 0);
  });

  testWidgets('音轨命令等待期间手动暂停，不升级重载或自动播放', (tester) async {
    recovery.dispose();
    final pending = Completer<bool>();
    recovery = PlaybackAudioRecovery(
      readState: () => playback.state,
      repairAudio: () => pending.future,
      reload: () async => reloads++,
      onError: errors.add,
    );
    playback.audioPts = null;
    audioError();
    await tick(tester);
    playback.playing = false;
    recovery.onPlaybackChanged();
    pending.complete(false);
    await tick(tester);
    expect(reloads, 0);
    expect(playback.playing, isFalse);
    recovery.dispose();
  });

  testWidgets('HTTP 403 终止音频恢复，后续解码错误不轮换 CDN', (tester) async {
    playback.audioPts = null;
    audioError();
    recovery.onLog(
      prefix: 'ffmpeg',
      level: 'error',
      message: 'http: HTTP error 403 Forbidden',
    );
    audioError();
    await tick(tester);
    expect(repairs, 0);
    expect(reloads, 0);
    recovery.observe();
    expect(statuses.last, AudioRecoveryStatus.failed);
    recovery.reset();
    audioError();
    await tick(tester);
    expect(repairs, 1);
    recovery.dispose();
  });
}

class _Playback {
  bool attached = true;
  bool playing = true;
  bool waiting = false;
  bool completed = false;
  Duration position = const Duration(seconds: 10);
  Duration duration = const Duration(seconds: 300);
  double? audioPts = 10;

  AudioRecoveryState get state => (
    playing: playing,
    waiting: waiting,
    completed: completed,
    position: position,
    duration: duration,
    audioPts: audioPts,
    audioProgressing: null,
    audioDelay: 0,
  );
}
