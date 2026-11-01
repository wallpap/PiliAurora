import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter/animation.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/common/widgets/scale_app.dart';
import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/models/common/home_tab_type.dart';
import 'package:pili_aurora/models/common/nav_bar_config.dart';
import 'package:pili_aurora/models/model_rec_video_item.dart';
import 'package:pili_aurora/pages/home/controller.dart';
import 'package:pili_aurora/pages/common/common_controller.dart';
import 'package:pili_aurora/pages/rank/controller.dart';
import 'package:pili_aurora/pages/main/controller.dart';
import 'package:pili_aurora/pages/rcmd/controller.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/process_metrics.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import 'memory_logging.dart' as logging;

Future<void> _until(bool Function() ready, String stage) async {
  final clock = Stopwatch()..start();
  while (!ready()) {
    if (clock.elapsed > const Duration(seconds: 60)) {
      throw TimeoutException(stage);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// 独立种子的真实页面复访与播放对照；仅在最终报告保存后卸载根页面。
Future<void> main(List<String> arguments) async {
  ScaledWidgetsFlutterBinding.ensureInitialized();
  final output = File(Platform.environment['PILIAURORA_STUTTER_OUTPUT']!);
  final frames = <Map<String, Object?>>[];
  final stages = <Map<String, Object?>>[];
  final events = <Map<String, Object?>>[];
  final gaps = <Map<String, Object?>>[];
  final snapshots = <Map<String, Object?>>[];
  final process = ProcessMetrics();
  final clock = Stopwatch()..start();
  final report = <String, Object?>{
    'schema': 1,
    'pid': pid,
    'state': 'running',
    'validWorkload': false,
    'frames': frames,
    'stages': stages,
    'events': events,
    'timerGaps': gaps,
    'playbackSnapshots': snapshots,
  };
  void timings(List<FrameTiming> values) {
    for (final f in values) {
      final finish = f.timestampInMicroseconds(FramePhase.rasterFinishWallTime);
      final start =
          finish -
          (f.timestampInMicroseconds(FramePhase.rasterFinish) -
              f.timestampInMicroseconds(FramePhase.buildStart));
      frames.add({
        'startUtcUs': start,
        'buildMs': f.buildDuration.inMicroseconds / 1000,
        'rasterMs': f.rasterDuration.inMicroseconds / 1000,
        'totalMs': f.totalSpan.inMicroseconds / 1000,
        'vsyncOverheadMs': f.vsyncOverhead.inMicroseconds / 1000,
      });
    }
  }

  SchedulerBinding.instance.addTimingsCallback(timings);
  var lastTick = clock.elapsedMicroseconds;
  final heartbeat = Timer.periodic(const Duration(milliseconds: 5), (_) {
    final now = clock.elapsedMicroseconds;
    final gap = now - lastTick;
    if (gap > 12000) {
      gaps.add({
        'utcUs': DateTime.now().toUtc().microsecondsSinceEpoch,
        'gapMs': gap / 1000,
      });
    }
    lastTick = now;
  });
  final diagnostics = Diagnostics.instance;
  Future<T> stage<T>(String name, Future<T> Function() work) async {
    await output.parent.create(recursive: true);
    await File('${output.parent.path}/progress.json').writeAsString(
      jsonEncode({
        'stage': name,
        'pid': pid,
        'elapsedMs': clock.elapsedMilliseconds,
      }),
    );
    final row = <String, Object?>{
      'name': name,
      'startUtcUs': DateTime.now().toUtc().microsecondsSinceEpoch,
    };
    stages.add(row);
    try {
      return await work();
    } finally {
      row['endUtcUs'] = DateTime.now().toUtc().microsecondsSinceEpoch;
      row['process'] = process.sample();
    }
  }

  void mark(String name) => events.add({
    'name': name,
    'utcUs': DateTime.now().toUtc().microsecondsSinceEpoch,
  });
  Future<void> pause(int ms) =>
      Future<void>.delayed(Duration(milliseconds: ms));
  Future<void> mode(String mode) async {
    await diagnostics.configure(
      level: mode == 'off' ? DiagnosticLogLevel.off : DiagnosticLogLevel.debug,
      playerLevel: mode == 'debug'
          ? DiagnosticLogLevel.debug
          : mode == 'off'
          ? DiagnosticLogLevel.off
          : DiagnosticLogLevel.info,
      tracing: mode != 'off',
      intervalMs: 250,
    );
    await pause(1500);
  }

  try {
    await stage('startup', () => logging.main(arguments));
    await _until(
      () =>
          Get.isRegistered<MainController>() &&
          Get.isRegistered<HomeController>() &&
          !SmartDialog.checkExist(),
      'startup',
    );
    final main = Get.find<MainController>();
    final home = Get.find<HomeController>();
    void selectMain(NavigationBarType tab) {
      final index = main.navigationBars.indexOf(tab);
      if (index < 0) throw StateError('missing main tab');
      if (main.selectedIndex.value != index) main.setIndex(index);
    }

    void selectHome(HomeTabType tab) {
      selectMain(NavigationBarType.home);
      final index = home.tabs.indexOf(tab);
      if (index < 0) throw StateError('missing home tab');
      if (home.tabController.index != index) {
        home.tabController.animateTo(index);
      }
    }

    const tabs = [
      HomeTabType.rcmd,
      HomeTabType.hot,
      HomeTabType.rank,
      HomeTabType.bangumi,
      HomeTabType.cinema,
      HomeTabType.live,
    ];
    final visits = <Map<String, Object?>>[];
    report['visits'] = visits;
    await mode('debug');
    for (final tab in tabs) {
      await stage('first:${tab.name}', () async {
        mark('first:${tab.name}');
        selectHome(tab);
        await pause(5000);
        final source = diagnostics.readSources(prefix: 'homePage');
        final controller = home.controller;
        final stateController = controller is RankController
            ? controller.controller
            : controller;
        final loaded =
            stateController is CommonController &&
            stateController.loadingState.value.isSuccess;
        visits.add({'tab': tab.name, 'source': source, 'loaded': loaded});
        final scroll = home.controller.scrollController;
        if (scroll.hasClients && scroll.positions.length == 1) {
          await scroll.animateTo(
            (scroll.position.viewportDimension * .8).clamp(
              0.0,
              scroll.position.maxScrollExtent,
            ),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOut,
          );
        }
        await pause(1500);
      });
    }
    // 顺序ABBA，减少预热及时间漂移对诊断开关对照的影响。
    for (final (i, label) in ['debug', 'off', 'off', 'debug'].indexed) {
      await mode(label);
      await stage('revisit:$i:$label', () async {
        for (var round = 0; round < 2; round++) {
          for (final tab in tabs) {
            mark('revisit:$i:$round:${tab.name}');
            selectHome(tab);
            await pause(800);
          }
          for (final tab in [
            NavigationBarType.dynamics,
            NavigationBarType.mine,
            NavigationBarType.home,
          ]) {
            mark('revisit:$i:$round:main:${tab.name}');
            selectMain(tab);
            await pause(800);
          }
        }
        await pause(1200);
      });
    }
    // 设置只影响隔离种子；播放固定同一条推荐，复测首次/再次起播。
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
    selectHome(HomeTabType.rcmd);
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
    final item = recommendations.loadingState.value.dataOrNull!
        .whereType<BaseRcmdVideoItemModel>()
        .where(
          (x) =>
              !recommendations.isPending(x) &&
              x.goto == 'av' &&
              (x.aid != null || x.bvid?.isNotEmpty == true) &&
              x.duration >= 90,
        )
        .first;
    final bvid = item.bvid ?? IdUtils.av2bv(item.aid!);
    final cid =
        item.cid ??
        (await SearchHttp.ab2cWithDimension(aid: item.aid, bvid: bvid))?.cid;
    if (cid == null) throw StateError('missing cid');
    for (var round = 0; round < 2; round++) {
      await mode('debug');
      final player = PlPlayerController.getInstance();
      player.volume.value = 0;
      player.muted.value = true;
      player.autoPipEnabled.value = false;
      player.continuePlayInBackground.value = false;
      final tag = 'stutter-probe-$round';
      await stage('load:$round', () async {
        mark('load:$round');
        PageUtils.toVideoPage(
          aid: item.aid,
          bvid: bvid,
          cid: cid,
          cover: item.cover,
          title: item.title,
          progress: 0,
          extraArguments: {'heroTag': tag},
        );
        await _until(
          () =>
              player.currentPlaybackSnapshot.phase == PlaybackPhase.ready &&
              player.currentPlaybackSnapshot.actual.playing == true &&
              player.videoFramePresented.value,
          'playing',
        );
      });
      final detail = Get.find<VideoDetailController>(tag: tag);
      final startPosition = player.positionInMilliseconds;
      for (final (i, label) in ['debug', 'off', 'off', 'debug'].indexed) {
        await mode(label);
        await stage('play:$round:$i:$label', () async {
          for (var second = 0; second < 8; second++) {
            snapshots.add({
              'utcUs': DateTime.now().toUtc().microsecondsSinceEpoch,
              'round': round,
              'mode': label,
              'sources': diagnostics.readSources(prefix: 'danmaku.layer'),
              'player': diagnostics.readSources(prefix: 'player.'),
            });
            await pause(1000);
          }
        });
      }
      report['playbackAdvancedMs$round'] =
          player.positionInMilliseconds - startPosition;
      await stage('return:$round', () async {
        Get.back<void>();
        await _until(() => detail.isClosed, 'detailClose');
        await player.playbackReleased.timeout(const Duration(seconds: 30));
        await pause(2000);
      });
    }
    report['validWorkload'] =
        visits.every((v) => v['loaded'] == true) &&
        (report['playbackAdvancedMs0'] as int) >= 25000 &&
        (report['playbackAdvancedMs1'] as int) >= 25000;
    report['state'] = 'completed';
  } catch (error, stack) {
    report['state'] = 'failed';
    report['errorType'] = error.runtimeType.toString();
    report['error'] = error.toString();
    report['stack'] = stack.toString();
  } finally {
    await pause(1500); // 等待最后一批FrameTiming上报。
    heartbeat.cancel();
    SchedulerBinding.instance.removeTimingsCallback(timings);
    await diagnostics.flush();
    report['finalProcess'] = process.sample();
    await output.parent.create(recursive: true);
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    await logging.closeProbeWindow();
  }
}
