import 'dart:async';
import 'dart:io' show Platform, Directory, File;

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/models/common/super_resolution_type.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:path/path.dart' as path;
import 'package:pili_aurora/models/common/account_type.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_status.dart';
import 'package:pili_aurora/plugin/pl_player/playback/audio_recovery.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_playback_runtime.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/player_diagnostics.dart';
import 'package:pili_aurora/services/audio_session.dart';
import 'package:pili_aurora/services/service_locator.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory shaderRoot;
  setUpAll(() async {
    shaderRoot = await Directory.systemTemp.createTemp('shader-preparation-');
    appSupportDirPath = shaderRoot.path;
    GStorage.setting = await Hive.openBox('setting', bytes: Uint8List(0));
    GStorage.video = await Hive.openBox('video', bytes: Uint8List(0));
    GStorage.localCache = await Hive.openBox('cache', bytes: Uint8List(0));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/wakelock'),
          (_) async => null,
        );
  });
  tearDownAll(() async {
    await Hive.close();
    await shaderRoot.delete(recursive: true);
  });

  _recoveryTest('超分资源准备失败保留档位，同档位选择可以重试', (f) async {
    await f.tester.pumpWidget(
      MaterialApp(builder: FlutterSmartDialog.init(), home: const Scaffold()),
    );
    await f.load(shaderEligible: true);
    f.controller.superResolutionType.value = SuperResolutionType.disable;
    final blocked = File(path.join(shaderRoot.path, 'anime_shaders'))
      ..writeAsStringSync('blocked');
    await f.tester.runAsync(
      () => f.controller.setShader(SuperResolutionType.efficiency),
    );
    expect(f.controller.superResolutionType.value, SuperResolutionType.disable);
    expect(f.controller.shadersDirPath, isNull);
    blocked.deleteSync();
    await f.tester.runAsync(
      () => f.controller.setShader(SuperResolutionType.efficiency),
    );
    expect(
      f.controller.superResolutionType.value,
      SuperResolutionType.efficiency,
    );
    expect(f.controller.shadersDirPath, isNotNull);
    final dismissed = SmartDialog.dismiss(status: .allToast);
    await f.tester.pumpAndSettle();
    await dismissed;
  });

  _recoveryTest('历史上报：启用期间暂停历史或退出账号，发送前立即停止上报', (f) async {
    final previous = Accounts.heartbeat;
    final previousPause = GStorage.localCache.get(LocalCacheKey.historyPause);
    addTearDown(() async {
      Accounts.accountMode[AccountType.heartbeat.index] = previous;
      if (previousPause == null) {
        await GStorage.localCache.delete(LocalCacheKey.historyPause);
      } else {
        await GStorage.localCache.put(
          LocalCacheKey.historyPause,
          previousPause,
        );
      }
    });
    f.controller.enableHeart = true;
    Accounts.accountMode[AccountType.heartbeat.index] = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '1', 'bili_jct': 'fixture'}),
      null,
      null,
    );
    await GStorage.localCache.put(LocalCacheKey.historyPause, true);
    expect(
      f.controller.makeHeartBeat(10, type: .completed, isManual: true),
      isNull,
    );
    await GStorage.localCache.put(LocalCacheKey.historyPause, false);
    Accounts.accountMode[AccountType.heartbeat.index] = AnonymousAccount();
    expect(
      f.controller.makeHeartBeat(10, type: .completed, isManual: true),
      isNull,
    );
  });

  for (final failure in [false, true]) {
    _recoveryTest('音频焦点：播放等待激活，${failure ? '异常' : '拒绝'}保留播放结果', (f) async {
      final previous = audioSessionHandler;
      final activated = Completer<void>();
      final handler = _AudioSession()
        ..change = (active) async {
          if (!active) return true;
          await activated.future;
          if (failure) throw StateError('synthetic focus failure');
          return false;
        };
      audioSessionHandler = handler;
      addTearDown(() => audioSessionHandler = previous);
      try {
        await f.load(start: PlaybackStartPolicy.pause);
        var completed = false;
        final playing = f.controller.play()..then((_) => completed = true);
        await f.tester.pump();
        expect(handler.activations, [true]);
        expect(completed, isFalse);
        expect(f.runtime.player.state.playing, isTrue);
        activated.complete();
        await playing;
        expect(completed, isTrue);
        expect(f.controller.wantsToPlay, isTrue);
        expect(
          Diagnostics.instance.recentLogs.any(
            (record) =>
                record['message'] == (failure ? '音频会话激活失败' : '音频会话未接受激活请求'),
          ),
          isTrue,
        );
        await f.controller.pause();
        expect(handler.activations, [true, false]);
      } finally {
        if (!activated.isCompleted) activated.complete();
        await f.tester.pump(const Duration(milliseconds: 300));
      }
    });
  }

  _recoveryTest('音频焦点：旧暂停已被后续播放取代时不释放新焦点', (f) async {
    final previous = audioSessionHandler;
    final handler = _AudioSession();
    audioSessionHandler = handler;
    addTearDown(() => audioSessionHandler = previous);
    await f.load();
    final paused = Completer<void>();
    f.runtime.beforePlaying = (playing) async {
      if (!playing) await paused.future;
    };
    try {
      final pausing = f.controller.pause();
      await f.tester.pump();
      final playing = f.controller.play();
      await f.tester.pump();
      paused.complete();
      await f.tester.pump();
      await Future.wait([pausing, playing]);
      expect(handler.activations, [true]);
      expect(f.controller.wantsToPlay, isTrue);
    } finally {
      if (!paused.isCompleted) paused.complete();
      await f.tester.pump();
    }
  });

  _recoveryTest('音频焦点：激活与释放串行，旧 owner 排队副作用失效', (f) async {
    final previous = audioSessionHandler;
    var activated = Completer<void>();
    final handler = _AudioSession()
      ..change = (active) async {
        if (active) await activated.future;
        return true;
      };
    audioSessionHandler = handler;
    addTearDown(() => audioSessionHandler = previous);
    try {
      await f.load(start: PlaybackStartPolicy.pause);
      final playing = f.controller.play();
      await f.tester.pump();
      final pausing = f.controller.pause();
      await f.tester.pump();
      expect(handler.activations, [true]);
      activated.complete();
      await f.tester.pump();
      await Future.wait([playing, pausing]);
      expect(handler.activations, [true, false]);

      activated = Completer<void>();
      final oldPlaying = f.controller.play();
      await f.tester.pump();
      final oldPausing = f.controller.pause();
      await f.tester.pump();
      f.controller.attachPlaybackOwner();
      activated.complete();
      await f.tester.pump();
      await Future.wait([oldPlaying, oldPausing]);
      expect(handler.activations, [true, false, true]);
    } finally {
      if (!activated.isCompleted) activated.complete();
      await f.tester.pump();
    }
  });

  final restoreWindow = <String, void Function(PlPlayerController)>{
    '普通恢复': (controller) => controller.onWindowRestore(),
    '最大化恢复': (controller) => controller.onWindowMaximize(),
    '退出最大化': (controller) => controller.onWindowUnmaximize(),
  };
  _recoveryTest('越界续播归零后，进度条立即交接到修正位置', (f) async {
    final plan = PlaybackPlan(
      contentKey: 'invalid-history-projection',
      source: PlaybackSourceSnapshot.fromDataSource(
        NetworkSource(
          videoSource: 'https://example.test/history.mp4',
          audioSource: null,
        ),
      ),
      timeline: const PlaybackTimeline(
        kind: PlaybackTimelineKind.onDemand,
        seekPolicy: PlaybackSeekPolicy.allowed,
        duration: Duration(seconds: 10),
      ),
      configuration: PlaybackConfiguration(),
      startPosition: const Duration(seconds: 20),
      reloadPosition: const Duration(seconds: 20),
    );
    final result = await f.controller.loadPlaybackPlan(
      owner: f.owner,
      plan: plan,
      start: PlaybackStartPolicy.pause,
      live: false,
    );
    await f.tester.pump();
    expect(result.outcome, LoadOutcome.ready);
    expect(f.runtime.loads.single.reloadPosition, Duration.zero);
    expect(f.controller.position.value, 0);
    expect(f.controller.positionInMilliseconds, 0);
  });

  for (final actualFallback in [false, true]) {
    _recoveryTest('来源查询越界归零并在后续进度持续推进：$actualFallback', (f) async {
      final plan = PlaybackPlan(
        contentKey: 'query-projection',
        source: PlaybackSourceSnapshot.fromDataSource(
          NetworkSource(
            videoSource: 'https://example.test/video.mp4',
            audioSource: null,
          ),
        ),
        timeline: PlaybackTimeline(
          kind: PlaybackTimelineKind.onDemand,
          seekPolicy: PlaybackSeekPolicy.allowed,
          duration: Duration(seconds: actualFallback ? 30 : 10),
        ),
        configuration: PlaybackConfiguration(),
        startPosition: const Duration(seconds: 20),
        reloadPosition: const Duration(seconds: 20),
      );
      if (actualFallback) {
        f.runtime.onLoadOverride = (plan, context) async {
          if (f.runtime.loads.length != 1) return null;
          f.runtime._events.add(
            PlaybackRuntimeStateChanged(
              runtimeId: f.runtime.runtimeId,
              loadId: context.loadId,
              actual: const PlaybackActual(duration: Duration(seconds: 10)),
            ),
          );
          return PlaybackRuntimeLoadResult(
            loaded: false,
            output: PlaybackOutputPreparation(
              strategy: PlaybackOutputStrategy.failed,
              evidence: 'eof',
              outputEpoch: context.loadId,
            ),
          );
        };
      }
      final result = await f.owner.query((_) async {
        f.controller.preparePlaybackPlan(
          owner: f.owner,
          plan: plan,
          live: false,
        );
        return plan;
      });
      await f.tester.pump();
      expect(result.outcome, LoadOutcome.ready);
      expect(f.runtime.loads, hasLength(actualFallback ? 2 : 1));
      expect(f.controller.position.value, 0);
      f.runtime.player.state.position = const Duration(seconds: 5);
      f.runtime.emitActual();
      await f.tester.pump();
      expect(f.controller.position.value, 5);
      f.runtime.emitActual();
      await f.tester.pump();
      expect(f.controller.position.value, 5);
    });
  }

  for (final entry in restoreWindow.entries) {
    _recoveryTest('最小化暂停后${entry.key}释放抑制并保留播放意图', (f) async {
      await f.load();
      f.controller.pauseOnMinimize.value = true;
      f.controller.onWindowMinimize();
      await f.tester.pump();
      expect(f.runtime.player.state.playing, isFalse);
      await f.tester.pump(const Duration(minutes: 30));
      entry.value(f.controller);
      await f.tester.pump();
      expect(f.controller.currentPlaybackSnapshot.inhibitors, isEmpty);
      expect(f.controller.wantsToPlay, isTrue);
      expect(f.runtime.player.state.playing, isTrue);
    });
  }

  _recoveryTest('最小化期间不将缺少显示回执当成视频故障，恢复可见后重新确认', (f) async {
    await f.load();
    f.controller.pauseOnMinimize.value = false;
    f.controller.onWindowMinimize();
    f.runtime.videoHealthy = false;
    await f.advance(12, refill: true);
    expect(f.runtime.loads, hasLength(1));
    expect(f.controller.isVideoStalled.value, isFalse);
    f.controller.onWindowMaximize();
    await f.advance(3);
    expect(f.runtime.loads, hasLength(2));
  });

  _recoveryTest('已排队的画面恢复在最小化后停止，重新可见后保留恢复机会', (f) async {
    await f.load();
    f.controller.pauseOnMinimize.value = false;
    f.runtime.videoHealthy = false;
    f.runtime.emitActual();
    f.controller.onWindowMinimize();
    await f.advance(6);
    expect(f.runtime.loads, hasLength(1));
    f.controller.onWindowRestore();
    await f.advance(3);
    expect(f.runtime.loads, hasLength(2));
  });

  _recoveryTest('短暂隐藏后恢复，重新等待完整的画面确认窗口', (f) async {
    await f.load();
    f.controller.pauseOnMinimize.value = false;
    f.runtime.videoHealthy = false;
    await f.advance(2);
    f.controller.onWindowMinimize();
    f.controller.onWindowRestore();
    await f.advance(2);
    expect(f.runtime.loads, hasLength(1));
    await f.advance(1);
    expect(f.runtime.loads, hasLength(2));
  });

  _recoveryTest('主窗口通过插件事件最小化再最大化仍恢复播放，关闭后注销监听', (f) async {
    await f.load();
    f.controller.pauseOnMinimize.value = true;
    Future<void> windowEvent(String name) async {
      const codec = StandardMethodCodec();
      final done = Completer<void>();
      f.tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'window_manager',
        codec.encodeMethodCall(MethodCall('onEvent', {'eventName': name})),
        (_) => done.complete(),
      );
      await f.tester.pump();
      await done.future;
    }

    expect(windowManager.hasListeners, isTrue);
    await windowEvent('minimize');
    expect(f.runtime.player.state.playing, isFalse);
    await windowEvent('maximize');
    expect(f.runtime.player.state.playing, isTrue);
    await f.controller.shutdownPlaybackFacade();
    await f.tester.pump();
    expect(windowManager.hasListeners, isFalse);
  }, skip: !Platform.isWindows);

  _recoveryTest('隐藏和窗口恢复事件交错时，重新可见才开始视频恢复', (f) async {
    await f.load();
    f.controller.pauseOnMinimize.value = false;
    f.controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
    f.controller.onWindowMinimize();
    f.runtime.videoHealthy = false;
    await f.advance(6);
    f.controller.onWindowMaximize();
    await f.advance(6);
    expect(f.runtime.loads, hasLength(1));
    f.controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
    await f.advance(3);
    expect(f.runtime.loads, hasLength(2));
  });

  _recoveryTest('最小化期间手动暂停，恢复窗口不覆盖新的暂停意图', (f) async {
    await f.load();
    f.controller.pauseOnMinimize.value = true;
    f.controller.onWindowMinimize();
    await f.controller.pause();
    f.controller.onWindowMaximize();
    await f.tester.pump();
    expect(f.controller.currentPlaybackSnapshot.inhibitors, isEmpty);
    expect(f.controller.wantsToPlay, isFalse);
    expect(f.runtime.player.state.playing, isFalse);
  });

  _recoveryTest('片尾跳转后控制器进度同步到新位置', (f) async {
    await f.load(local: true);
    f.runtime.complete();
    await f.tester.pump();
    expect(f.controller.playerStatus, PlayerStatus.completed);
    f.controller.position.value = 300;
    f.controller.updateDuration(const Duration(minutes: 5));
    await f.controller.seekTo(const Duration(seconds: 42));
    await f.tester.pump();
    expect(f.controller.position.value, 42);
    expect(f.controller.positionInMilliseconds, 42000);
    expect(f.controller.playerStatus, PlayerStatus.paused);
  });

  _recoveryTest('片尾连续跳转时旧结果不覆盖最新进度', (f) async {
    await f.load(local: true);
    f.runtime.complete();
    await f.tester.pump();
    f.controller.position.value = 300;
    f.controller.updateDuration(const Duration(minutes: 5));
    final gate = Completer<void>();
    f.runtime.beforeLoad = (plan) async {
      if (plan.reloadPosition == const Duration(seconds: 42)) await gate.future;
    };
    final first = f.controller.seekTo(const Duration(seconds: 42));
    await f.tester.pump();
    final latest = f.controller.seekTo(const Duration(seconds: 90));
    await f.tester.pump();
    gate.complete();
    await Future.wait([first, latest]);
    await f.tester.pump();
    expect(f.controller.position.value, 90);
    expect(f.controller.positionInMilliseconds, 90000);
  });

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
    await f.reachSecondThrottledRecovery();
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

  for (final unsupported in [false, true]) {
    _recoveryTest('音量回执：静音${unsupported ? '拒绝' : '失败'}返回原因并可重试', (f) async {
      await f.load();
      const failure = PlaybackFailure(
        category: PlaybackFailureCategory.audio,
        operation: 'volume',
        stage: PlaybackStage.observing,
        recoverable: true,
        cause: 'synthetic volume failure',
      );
      f.runtime.onVolume = (_) async => PlaybackRuntimeCommandResult(
        applied: false,
        failure: unsupported ? null : failure,
      );
      for (var i = 0; i < 2; i++) {
        await expectLater(
          f.controller.setMuted(true),
          throwsA(
            isA<PlayerVolumeException>()
                .having(
                  (error) => error.result.outcome,
                  'outcome',
                  unsupported
                      ? CommandOutcome.unsupported
                      : CommandOutcome.failed,
                )
                .having(
                  (error) => error.result.failure,
                  'failure',
                  unsupported ? isNull : same(failure),
                ),
          ),
        );
        f.runtime.emitActual();
        await f.tester.pump();
        expect(f.controller.isMuted, isFalse);
        expect(f.controller.volume.value, 1);
        expect(
          f.controller.currentPlaybackSnapshot.configuration.desired.volume,
          100,
        );
      }
      f.runtime.onVolume = null;
      await f.controller.setMuted(true);
      expect(f.runtime.volumes, [0, 100, 0, 100, 0]);
      expect(f.controller.isMuted, isTrue);
      await f.controller.setMuted(false);
      expect(f.runtime.player.state.volume, 100);
    });
  }

  _recoveryTest('音量回执：取消静音失败保留静音和原有音量', (f) async {
    await f.load();
    await f.controller.setVolume(.4, showIndicator: false);
    await f.controller.setMuted(true);
    f.runtime.onVolume = (_) async => const PlaybackRuntimeCommandResult(
      applied: false,
    );
    await expectLater(
      f.controller.setMuted(false),
      throwsA(isA<PlayerVolumeException>()),
    );
    expect(f.controller.isMuted, isTrue);
    expect(f.controller.volume.value, .4);
    expect(
      f.controller.currentPlaybackSnapshot.configuration.desired.volume,
      0,
    );
    f.runtime.onVolume = null;
    await f.controller.setMuted(false);
    expect(f.runtime.player.state.volume, 40);
    expect(f.controller.volume.value, .4);
  });

  _recoveryTest('音量回执：迟到静音失败不覆盖新调节和保存值', (f) async {
    await f.load();
    final pending = Completer<PlaybackRuntimeCommandResult>();
    f.runtime.onVolume = (value) => value == 0
        ? pending.future
        : Future.value(const PlaybackRuntimeCommandResult());
    final muted = expectLater(
      f.controller.setMuted(true),
      throwsA(
        isA<PlayerVolumeException>().having(
          (error) => error.isObsolete,
          'obsolete',
          isTrue,
        ),
      ),
    );
    await f.tester.pump();
    final volume = f.controller.setVolume(.6, showIndicator: false);
    await f.tester.pump();
    pending.complete(const PlaybackRuntimeCommandResult(applied: false));
    await f.tester.pump();
    await Future.wait([muted, volume]);
    expect(f.controller.isMuted, isFalse);
    expect(f.controller.volume.value, .6);
    expect(f.runtime.player.state.volume, 60);
    await f.tester.pump(const Duration(milliseconds: 200));
    expect(GStorage.setting.get(SettingBoxKey.desktopVolume), .6);
  }, skip: !Platform.isWindows);

  _recoveryTest('音量回执：切源后旧静音失败不回滚新媒体', (f) async {
    await f.load();
    final pending = Completer<PlaybackRuntimeCommandResult>();
    f.runtime.onVolume = (value) => value == 0
        ? pending.future
        : Future.value(const PlaybackRuntimeCommandResult());
    final muted = expectLater(
      f.controller.setMuted(true),
      throwsA(
        isA<PlayerVolumeException>().having(
          (error) => error.isObsolete,
          'obsolete',
          isTrue,
        ),
      ),
    );
    await f.tester.pump();
    final original = f.runtime.loads.single;
    final switching = f.controller.loadPlaybackPlan(
      owner: f.owner,
      plan: PlaybackPlan(
        contentKey: 'next',
        source: original.source,
        timeline: original.timeline,
        configuration: PlaybackConfiguration(),
      ),
      start: PlaybackStartPolicy.play,
      live: false,
    );
    await f.tester.pump();
    final unmuting = f.controller.setMuted(false);
    pending.complete(const PlaybackRuntimeCommandResult(applied: false));
    await f.tester.pump();
    await Future.wait([muted, unmuting]);
    expect((await switching).outcome, LoadOutcome.ready);
    expect(f.controller.isMuted, isFalse);
    expect(f.controller.volume.value, 1);
    expect(f.runtime.volumes, [0]);
    expect(f.runtime.loads.last.configuration.volume, 100);
  });

  _recoveryTest('音量回执：控件消费失败，失败调节不保存为成功音量', (f) async {
    await f.tester.pumpWidget(
      MaterialApp(
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(),
      ),
    );
    SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);
    try {
      await f.load();
      f.runtime.onVolume = (_) async => const PlaybackRuntimeCommandResult(
        applied: false,
      );
      await f.controller.setMutedFromControls(true, showSuccess: true);
      await f.tester.pump(const Duration(milliseconds: 300));
      expect(find.text('音量设置失败，请重试'), findsOneWidget);
      expect(find.text('静音'), findsNothing);
      await f.controller.setVolume(.3, showIndicator: false);
      await f.tester.pump(const Duration(milliseconds: 200));
      expect(f.controller.isMuted, isFalse);
      expect(f.controller.volume.value, 1);
      expect(GStorage.setting.get(SettingBoxKey.desktopVolume), 1);
    } finally {
      await f.tester.pump(const Duration(seconds: 6));
      await f.tester.pumpWidget(const SizedBox());
      await f.tester.pump();
    }
  }, skip: !Platform.isWindows);

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
    await f.reachSecondThrottledRecovery();
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
  bool skip = false,
}) {
  testWidgets(name, (tester) async {
    final f = _Fixture(tester, mode: mode);
    try {
      await body(f);
    } finally {
      await f.dispose();
    }
  }, skip: skip);
}

enum _Mode { separate, combined, audioOnly, videoOnly }

class _AudioSession extends AudioSessionHandler {
  final activations = <bool>[];
  Future<bool> Function(bool)? change;

  @override
  Future<bool> setActive(bool active) async {
    activations.add(active);
    return change?.call(active) ?? true;
  }
}

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
    bool shaderEligible = false,
    PlaybackStartPolicy start = PlaybackStartPolicy.play,
    bool local = false,
    List<String> videoCandidates = const [],
    List<String> audioCandidates = const [],
  }) async {
    runtime.hasVideo = mode != _Mode.audioOnly;
    runtime.hasAudio = mode != _Mode.videoOnly;
    final plan = PlaybackPlan(
      contentKey: key,
      metadata: shaderEligible
          ? const PlaybackMetadataHint(trust: .sourceHint, width: 1, height: 1)
          : null,
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

  // 两个终态共用前半段限频轨迹：3 秒首次恢复，再等待满 10 秒。
  Future<void> reachSecondThrottledRecovery() async {
    await load();
    runtime
      ..recoverOnLoad = false
      ..videoHealthy = false;
    await advance(3);
    expect(runtime.loads, hasLength(2));
    await advance(9);
    expect(runtime.loads, hasLength(2));
    await advance(1);
    expect(runtime.loads, hasLength(3));
  }

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
  Future<void> Function(PlaybackPlan)? beforeLoad;
  Future<PlaybackRuntimeLoadResult?> Function(
    PlaybackPlan,
    PlaybackExecutionContext,
  )?
  onLoadOverride;
  bool hasVideo = true;
  bool hasAudio = true;
  bool videoHealthy = true;
  bool audioHealthy = true;
  bool recoverOnLoad = true;
  bool seeking = false;
  int loadId = 0;
  int repairs = 0;
  Future<PlaybackRuntimeCommandResult> Function()? onRepair;
  final volumes = <double>[];
  Future<PlaybackRuntimeCommandResult> Function(double)? onVolume;
  Future<void> Function(bool)? beforePlaying;

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
    final override = await onLoadOverride?.call(plan, context);
    if (override != null) return override;
    await beforeLoad?.call(plan);
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
    if (beforePlaying case final before?) await before(value);
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
  Future<PlaybackRuntimeCommandResult> setShader(
    List<String> shaders,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

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
    volumes.add(value);
    final result =
        await onVolume?.call(value) ?? const PlaybackRuntimeCommandResult();
    if (context.isCurrent() && result.applied && result.failure == null) {
      player.state.volume = value;
    }
    return result;
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
