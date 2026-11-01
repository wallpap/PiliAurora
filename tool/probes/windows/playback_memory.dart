import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/models/common/home_tab_type.dart';
import 'package:pili_aurora/models/common/nav_bar_config.dart';
import 'package:pili_aurora/models/model_rec_video_item.dart';
import 'package:pili_aurora/pages/home/controller.dart';
import 'package:pili_aurora/pages/main/controller.dart';
import 'package:pili_aurora/pages/rcmd/controller.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/services/desktop_playback_windows.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/process_metrics.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import 'memory_logging.dart' as logging;

const _native = MethodChannel('com.alexmercerind/media_kit_video');

Future<void> _until(
  bool Function() ready,
  String stage, {
  int seconds = 45,
}) async {
  final clock = Stopwatch()..start();
  while (!ready()) {
    if (clock.elapsed >= Duration(seconds: seconds)) {
      throw TimeoutException(stage);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

/// 独立种子下的真实页面播放/返回，不替换根Widget、不强制关闭播放会话。
Future<void> main(List<String> arguments) async {
  final output = File(
    Platform.environment['PILIAURORA_PLAYBACK_OUTPUT'] ??
        '${File(Platform.resolvedExecutable).parent.path}/playback-probe.json',
  );
  final playSeconds =
      (int.tryParse(
                Platform.environment['PILIAURORA_PLAYBACK_SECONDS'] ?? '',
              ) ??
              20)
          .clamp(1, 120);
  final idleSeconds =
      (int.tryParse(
                Platform.environment['PILIAURORA_PLAYBACK_IDLE_SECONDS'] ?? '',
              ) ??
              70)
          .clamp(1, 300);
  final stages = <Map<String, Object?>>[];
  final rounds = <Map<String, Object?>>[];
  final report = <String, Object?>{
    'schemaVersion': 1,
    'state': 'running',
    'scope': 'realAppRecommendationVideoRoute; noCachePurgeOrRootReplacementDuringMeasurement',
    'shutdownPolicy': 'unmountWidgetsAfterFinalSnapshotThenDestroyHost',
    'playSeconds': playSeconds,
    'idleSeconds': idleSeconds,
    'validWorkload': false,
    'passed': false,
    'rounds': rounds,
    'stages': stages,
  };
  final clock = Stopwatch()..start();
  final process = ProcessMetrics();
  final diagnostics = Diagnostics.instance;

  Future<Map<String, Object?>> record(String stage) async {
    Map<String, Object?> native;
    try {
      native =
          await _native
              .invokeMapMethod<String, Object?>(
                'VideoOutputManager.MemoryStats',
              )
              .timeout(const Duration(seconds: 5)) ??
          const {'status': 'empty'};
    } catch (error) {
      native = {
        'status': 'unavailable',
        'errorType': error.runtimeType.toString(),
      };
    }
    final sample = <String, Object?>{
      'stage': stage,
      'time': DateTime.now().toUtc().toIso8601String(),
      'elapsedMs': clock.elapsedMilliseconds,
      'process': process.sample(),
      'native': native,
    };
    stages.add(sample);
    await output.parent.create(recursive: true);
    await File('${output.parent.path}/playback-progress.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    return sample;
  }

  try {
    if (!Platform.isWindows ||
        Platform.environment['PILIAURORA_MEMORY_ROOT']?.isNotEmpty != true) {
      throw StateError('Windows and explicit isolated memory root required');
    }
    await logging
        .main(arguments.where((arg) => arg != '--smoke').toList())
        .timeout(const Duration(seconds: 90));
    if (DesktopPlaybackWindows.isPlayerWindow) {
      throw StateError('main test process required');
    }
    // logging.main已将PathProvider/GStorage指向独立种子，以下不触碰现用设置。
    for (final entry in {
      SettingBoxKey.desktopVolume: 0.0,
      SettingBoxKey.playerVolume: 0.0,
      SettingBoxKey.enableAutoEnter: false,
      SettingBoxKey.autoPiP: false,
      SettingBoxKey.continuePlayInBackground: false,
      SettingBoxKey.autoPlayEnable: true,
    }.entries) {
      await GStorage.setting.put(entry.key, entry.value);
    }
    report['testPreferences'] = {
      'desktopVolume': 0,
      'playerVolume': 0,
      'autoFullscreen': false,
      'autoPiP': false,
      'backgroundPlayback': false,
      'windowPolicy':
          'PageUtils.toVideoPageInMainProcess; noDesktopWindowOpenCall',
    };
    await _until(
      () =>
          Get.isRegistered<MainController>() &&
          Get.isRegistered<HomeController>() &&
          !SmartDialog.checkExist(),
      'startup',
    );
    await record('baseline');
    for (var round = 1; round <= 2; round++) {
      final result = <String, Object?>{
        'round': round,
        'validWorkload': false,
        'loadOutcome': 'notRequested',
        'shutdownOutcome': 'notObserved',
      };
      rounds.add(result);
      try {
        if (Get.currentRoute == '/setting') {
          Get.back<void>();
          await _until(
            () => Get.currentRoute != '/setting',
            'returnFromSettings',
          );
        }
        final main = Get.find<MainController>();
        final home = Get.find<HomeController>();
        final homeIndex = main.navigationBars.indexOf(NavigationBarType.home);
        final rcmdIndex = home.tabs.indexOf(HomeTabType.rcmd);
        if (homeIndex < 0 || rcmdIndex < 0) {
          throw StateError('recommendation tab unavailable');
        }
        if (main.selectedIndex.value != homeIndex) main.setIndex(homeIndex);
        if (home.tabController.index != rcmdIndex) {
          home.tabController.animateTo(rcmdIndex);
        }
        await _until(
          () =>
              Get.isRegistered<RcmdController>() &&
              (Get.find<RcmdController>()
                      .loadingState
                      .value
                      .dataOrNull
                      ?.isNotEmpty ??
                  false),
          'recommendations',
        );
        final recommendations = Get.find<RcmdController>();
        final candidate = recommendations.loadingState.value.dataOrNull!
            .whereType<BaseRcmdVideoItemModel>()
            .where(
              (item) =>
                  !recommendations.isPending(item) &&
                  item.goto == 'av' &&
                  (item.aid != null || item.bvid?.isNotEmpty == true) &&
                  (item.duration <= 0 || item.duration >= playSeconds + 5),
            )
            .firstOrNull;
        if (candidate == null) {
          throw StateError('no playable ordinary AV recommendation');
        }
        var cid = candidate.cid;
        final bvid = candidate.bvid ?? IdUtils.av2bv(candidate.aid!);
        cid ??= (await SearchHttp.ab2cWithDimension(
          aid: candidate.aid,
          bvid: bvid,
        ).timeout(const Duration(seconds: 20)))?.cid;
        if (cid == null || cid <= 0) throw StateError('CID lookup failed');
        result['recommendationSource'] =
            'firstEligibleAv; identifiersAndTitleOmitted';
        final player = PlPlayerController.getInstance();
        player.volume.value = 0;
        player.muted.value = true;
        player.autoPipEnabled.value = false;
        player.continuePlayInBackground.value = false;
        final tag = 'playback-memory-round-$round';
        final routeClosed = PageUtils.toVideoPage(
          aid: candidate.aid,
          bvid: bvid,
          cid: cid,
          cover: candidate.cover,
          title: candidate.title,
          progress: 0,
          extraArguments: {'heroTag': tag},
        );
        result['loadOutcome'] = 'routeRequested';
        await _until(
          () => Get.isRegistered<VideoDetailController>(tag: tag),
          'videoController',
        );
        final detail = Get.find<VideoDetailController>(tag: tag);
        if (!identical(detail.plPlayerController, player)) {
          throw StateError('unexpected playback facade');
        }
        await _until(
          () {
            final snapshot = player.currentPlaybackSnapshot;
            if (snapshot.phase == PlaybackPhase.failed) {
              throw StateError('playback load failed');
            }
            return snapshot.phase == PlaybackPhase.ready &&
                snapshot.actual.playing == true &&
                player.videoFramePresented.value;
          },
          'readyPlayingWithPresentedFrame',
          seconds: 60,
        );
        result['loadOutcome'] = 'observedReadyPlayingAndFramePresented';
        final startPosition = player.positionInMilliseconds;
        final playing = await record('round$round:playing');
        await Future<void>.delayed(Duration(seconds: playSeconds));
        final advanced = player.positionInMilliseconds - startPosition;
        result['advancedMs'] = advanced;
        final actuallyPlayed =
            advanced >= playSeconds * 1000 * 0.75 &&
            player.videoFramePresented.value &&
            player.currentPlaybackSnapshot.actual.playing == true;
        result['playbackProgressPassed'] = actuallyPlayed;
        final outputStats =
            ((playing['native'] as Map)['resources'] as Map?)?['videoOutput']
                as Map?;
        result['nativeOutputObserved'] =
            (outputStats?['count'] as num? ?? 0) > 0;
        await record('round$round:played');
        Get.back<void>();
        await routeClosed?.timeout(const Duration(seconds: 10));
        await _until(
          () => detail.isClosed,
          'videoControllerNormalClose',
          seconds: 15,
        );
        // 只观察正常路由释放；不调用shutdownPlaybackFacade来掩盖关闭遗漏。
        await player.playbackReleased.timeout(const Duration(seconds: 30));
        result['shutdownOutcome'] = 'observedNormalRouteRuntimeReleased';
        result['shutdownPhase'] = player.currentPlaybackSnapshot.phase.name;
        await record('round$round:normalRouteReleased');
        unawaited(Get.toNamed<void>('/setting'));
        await _until(() => Get.currentRoute == '/setting', 'settings');
        await Future<void>.delayed(Duration(seconds: idleSeconds));
        final idle = await record('round$round:settingIdle');
        final memory = idle['process'] as Map;
        final native = idle['native'] as Map;
        final resources = native['resources'] as Map?;
        final released =
            (resources?['videoOutput'] as Map?)?['count'] == 0 &&
            native['pendingTextureUnregistrations'] == 0 &&
            native['releasingOutputs'] == 0;
        final privateBytes = memory['privateBytes'] as num?;
        final rssBytes = memory['rssBytes'] as num?;
        result['nativeResourcesReleased'] = released;
        result['retentionTargetPassed'] =
            privateBytes != null &&
            rssBytes != null &&
            privateBytes < 500 * 1024 * 1024 &&
            rssBytes < 500 * 1024 * 1024;
        result['validWorkload'] =
            actuallyPlayed && result['nativeOutputObserved'] == true;
        result['passed'] =
            result['validWorkload'] == true &&
            released &&
            result['retentionTargetPassed'] == true;
      } catch (error) {
        result['errorType'] = error.runtimeType.toString();
        result['passed'] = false;
        // 仍通过正常导航返回主路由，避免下一轮把上一轮视频留在栈上。
        Get.until((route) => route.isFirst);
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    report['validWorkload'] =
        rounds.length == 2 &&
        rounds.every((round) => round['validWorkload'] == true);
    report['passed'] =
        report['validWorkload'] == true &&
        rounds.every((round) => round['passed'] == true);
    report['state'] = 'completed';
  } catch (error) {
    report['state'] = 'failed';
    report['errorType'] = error.runtimeType.toString();
  } finally {
    report['elapsedMs'] = clock.elapsedMilliseconds;
    try {
      await record('finalSnapshot');
      await diagnostics.flush().timeout(const Duration(seconds: 15));
    } catch (error) {
      report['state'] = 'failed';
      report['passed'] = false;
      report['finalizeErrorType'] = error.runtimeType.toString();
    }
    try {
      await output.parent.create(recursive: true);
      await output.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
    } finally {
      await logging.closeProbeWindow();
    }
  }
}
