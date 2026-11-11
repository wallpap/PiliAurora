import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as web;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/http/search.dart';
import 'package:pili_aurora/common/widgets/webview_ready.dart';
import 'package:pili_aurora/models/common/home_tab_type.dart';
import 'package:pili_aurora/models/common/nav_bar_config.dart';
import 'package:pili_aurora/models/model_rec_video_item.dart';
import 'package:pili_aurora/pages/common/common_controller.dart';
import 'package:pili_aurora/pages/home/controller.dart';
import 'package:pili_aurora/pages/main/controller.dart';
import 'package:pili_aurora/pages/rcmd/controller.dart';
import 'package:pili_aurora/pages/rank/controller.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/services/desktop_playback_windows.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/process_metrics.dart';
import 'package:pili_aurora/services/webview_environment.dart';
import 'package:pili_aurora/utils/login_utils.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/page_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

import 'memory_logging.dart' as logging;
import 'process_heap_memory.dart';

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
  final cacheMiB = int.tryParse(
    Platform.environment['PILIAURORA_SKIA_CACHE_MIB'] ?? '',
  );
  final imageCacheMiB = int.tryParse(
    Platform.environment['PILIAURORA_IMAGE_CACHE_MIB'] ?? '',
  );
  final browseExercise =
      Platform.environment['PILIAURORA_PLAYBACK_BROWSE'] == '1';
  final optimizeIdleHeaps =
      Platform.environment['PILIAURORA_OPTIMIZE_IDLE_HEAPS'] == '1';
  final scrollExercise =
      Platform.environment['PILIAURORA_PLAYBACK_SCROLL'] == '1';
  final candidatePath = Platform.environment['PILIAURORA_PLAYBACK_CANDIDATE'];
  final eagerWebView = Platform.environment['PILIAURORA_WEBVIEW_EAGER'] == '1';
  final exerciseWebView =
      Platform.environment['PILIAURORA_EXERCISE_WEBVIEW'] == '1';
  final webViewOnly = Platform.environment['PILIAURORA_WEBVIEW_ONLY'] == '1';
  final retainWebView =
      Platform.environment['PILIAURORA_WEBVIEW_RETAIN'] == '1';
  final local4k = Platform.environment['PILIAURORA_PLAYBACK_LOCAL_4K'];
  void Function()? releaseWebControl;
  final frames = <ui.FrameTiming>[];
  var measuringFrames = false;
  void onTimings(List<ui.FrameTiming> values) {
    if (measuringFrames) frames.addAll(values);
  }

  Map<String, Object?> frameSummary() {
    final raster =
        frames.map((frame) => frame.rasterDuration.inMicroseconds).toList()
          ..sort();
    final build =
        frames.map((frame) => frame.buildDuration.inMicroseconds).toList()
          ..sort();
    return {
      'count': frames.length,
      if (frames.isNotEmpty) ...{
        'rasterP95Ms': raster[((raster.length - 1) * .95).round()] / 1000,
        'rasterMaxMs': raster.last / 1000,
        'buildP95Ms': build[((build.length - 1) * .95).round()] / 1000,
        'rasterOver16ms': raster.where((value) => value > 16667).length,
      },
    };
  }

  final report = <String, Object?>{
    'schemaVersion': 1,
    'state': 'running',
    'scope': webViewOnly
        ? 'realAppWebViewInitializationOnly; noGcOrWorkingSetTrim'
        : 'realAppBrowsingAndPlayback; optionalNativeWebView; noCachePurgeOrRootReplacementDuringMeasurement',
    'shutdownPolicy': 'unmountWidgetsAfterFinalSnapshotThenDestroyHost',
    'playSeconds': playSeconds,
    'idleSeconds': idleSeconds,
    'skiaCacheMaxMiB': cacheMiB,
    'imageCacheMaxMiB': imageCacheMiB,
    'browseExercise': browseExercise,
    'optimizeIdleHeaps': optimizeIdleHeaps,
    'eagerWebViewControl': eagerWebView,
    'exerciseWebView': exerciseWebView,
    'webViewOnly': webViewOnly,
    'scrollExercise': scrollExercise,
    'validWorkload': false,
    'passed': false,
    'rounds': rounds,
    'stages': stages,
  };
  final clock = Stopwatch()..start();
  final process = ProcessMetrics();
  final heap = ProcessHeapMemory();
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
      'defaultHeap': heap.sample(),
      'route': Get.currentRoute,
      'images': {
        'cacheBytes': PaintingBinding.instance.imageCache.currentSizeBytes,
        'cacheEntries': PaintingBinding.instance.imageCache.currentSize,
        'liveImages': PaintingBinding.instance.imageCache.liveImageCount,
        'pendingImages': PaintingBinding.instance.imageCache.pendingImageCount,
        'limitBytes': PaintingBinding.instance.imageCache.maximumSizeBytes,
      },
      'graphicsHandles': diagnostics.latest?['graphicsHandles'],
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
    WidgetsBinding.instance.addTimingsCallback(onTimings);
    if (retainWebView) releaseWebControl = AppWebViewEnvironment.retain();
    if (eagerWebView) {
      await AppWebViewEnvironment.ensureInitialized();
      await LoginUtils.setWebCookie();
    }
    if (cacheMiB != null) {
      if (cacheMiB < 1) throw ArgumentError('Positive cache size required');
      await SystemChannels.skia.invokeMethod<void>(
        'Skia.setResourceCacheMaxBytes',
        cacheMiB * 1048576,
      );
    }
    if (imageCacheMiB != null) {
      if (imageCacheMiB < 1) {
        throw ArgumentError('Positive image cache size required');
      }
      PaintingBinding.instance.imageCache.maximumSizeBytes =
          imageCacheMiB * 1048576;
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
    for (var round = 1; round <= (webViewOnly ? 0 : 2); round++) {
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
        if (browseExercise) {
          final visits = <Map<String, Object?>>[];
          result['browseVisits'] = visits;
          for (final tab in const [
            HomeTabType.rcmd,
            HomeTabType.hot,
            HomeTabType.rank,
            HomeTabType.bangumi,
            HomeTabType.cinema,
            HomeTabType.live,
          ]) {
            final index = home.tabs.indexOf(tab);
            if (index < 0) continue;
            if (home.tabController.index != index) {
              home.tabController.animateTo(index);
            }
            final visit = <String, Object?>{'tab': tab.name};
            frames.clear();
            measuringFrames = true;
            try {
              await Future<void>.delayed(const Duration(milliseconds: 400));
              await _until(
                () {
                  final selected = home.controller;
                  final controller = selected is RankController
                      ? selected.controller
                      : selected;
                  return controller is CommonController &&
                      controller.loadingState.value.isSuccess;
                },
                'browse:${tab.name}',
                seconds: 20,
              );
              await Future<void>.delayed(const Duration(seconds: 2));
              final selected = home.controller;
              final controller = selected is RankController
                  ? selected.controller
                  : selected;
              final data = controller is CommonController
                  ? controller.loadingState.value.dataOrNull
                  : null;
              visit['items'] = data is List ? data.length : null;
              final scroll = controller.scrollController;
              if (scroll.hasClients && scroll.positions.length == 1) {
                final distance = (scroll.position.viewportDimension * .75)
                    .clamp(0.0, scroll.position.maxScrollExtent * .5);
                await scroll.animateTo(
                  distance,
                  duration: const Duration(milliseconds: 800),
                  curve: Curves.linear,
                );
                visit['scrollDistance'] = distance;
              }
              visit['loaded'] = true;
            } catch (error) {
              visit['loaded'] = false;
              visit['errorType'] = error.runtimeType.toString();
            }
            await Future<void>.delayed(const Duration(milliseconds: 300));
            measuringFrames = false;
            visit['frames'] = frameSummary();
            visits.add(visit);
            await record('round$round:browse:${tab.name}');
          }
          result['browsePassed'] =
              visits.length >= 4 &&
              visits.every((visit) => visit['loaded'] == true);
        }
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
        // 为首屏图片预留加载时间，减少首次填充对播放前后差值的影响。
        await Future<void>.delayed(const Duration(seconds: 4));
        if (scrollExercise) {
          final scroll = recommendations.scrollController;
          await _until(() => scroll.hasClients, 'recommendationScroll');
          // 固定首屏附近往返，避免翻到底部触发更多分页。
          final distance = (scroll.position.viewportDimension * .75).clamp(
            0.0,
            scroll.position.maxScrollExtent * .5,
          );
          frames.clear();
          measuringFrames = true;
          for (var pass = 0; pass < 3; pass++) {
            await scroll.animateTo(
              distance,
              duration: const Duration(milliseconds: 800),
              curve: Curves.linear,
            );
            await scroll.animateTo(
              0,
              duration: const Duration(milliseconds: 800),
              curve: Curves.linear,
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
          measuringFrames = false;
          result['scrollDistance'] = distance;
          result['scrollFrames'] = frameSummary();
        }
        await record('round$round:beforePlayback');
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
        Map<String, dynamic>? pinned;
        if (candidatePath != null && File(candidatePath).existsSync()) {
          pinned = jsonDecode(
            await File(candidatePath).readAsString(),
          ) as Map<String, dynamic>;
        }
        final aid = pinned?['aid'] as int? ?? candidate.aid;
        var cid = pinned?['cid'] as int? ?? candidate.cid;
        final bvid =
            pinned?['bvid'] as String? ?? candidate.bvid ?? IdUtils.av2bv(aid!);
        final cover = pinned?['cover'] as String? ?? candidate.cover;
        final title = pinned?['title'] as String? ?? candidate.title;
        cid ??= (await SearchHttp.ab2cWithDimension(
          aid: aid,
          bvid: bvid,
        ).timeout(const Duration(seconds: 20)))?.cid;
        if (cid == null || cid <= 0) throw StateError('CID lookup failed');
        if (candidatePath != null && pinned == null) {
          await File(candidatePath).writeAsString(
            jsonEncode({
              'aid': aid,
              'cid': cid,
              'bvid': bvid,
              'cover': cover,
              'title': title,
            }),
          );
        }
        result['recommendationSource'] =
            '${candidatePath == null ? 'firstEligibleAv' : 'pinnedLocalCandidate'}; identifiersAndTitleOmitted';
        final player = PlPlayerController.getInstance();
        player.volume.value = 0;
        player.muted.value = true;
        player.autoPipEnabled.value = false;
        player.continuePlayInBackground.value = false;
        final tag = 'playback-memory-round-$round';
        final readyWatch = Stopwatch()..start();
        final routeClosed = PageUtils.toVideoPage(
          aid: aid,
          bvid: bvid,
          cid: cid,
          cover: cover,
          title: title,
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
        if (local4k != null) {
          if (!File(local4k).existsSync()) {
            throw StateError('Missing local 4K fixture');
          }
          final previous = player.currentPlaybackPlan!;
          final loaded = await detail.loadPlaybackPlanForRoute(
            PlaybackPlan(
              contentKey: previous.contentKey,
              source: PlaybackSourceSnapshot.fromDataSource(
                NetworkSource(
                  videoSource: File(local4k).uri.toString(),
                  audioSource: null,
                ),
              ),
              timeline: previous.timeline,
              configuration: previous.configuration,
              metadata: const PlaybackMetadataHint(
                trust: PlaybackMetadataTrust.sourceHint,
                width: 3840,
                height: 2160,
              ),
            ),
            start: PlaybackStartPolicy.play,
            onReady: () {},
          );
          if (loaded.outcome != LoadOutcome.ready) {
            throw StateError('4K load failed');
          }
          await _until(
            () =>
                player.videoPlayerController?.state.width == 3840 &&
                player.videoFramePresented.value &&
                player.currentPlaybackSnapshot.actual.playing == true,
            '4K presented',
          );
          final fps = player.videoPlayerController?.getProperty(
            'container-fps',
          );
          result['local4kFps'] = fps;
          if ((double.tryParse('$fps') ?? 0) < 59) {
            throw StateError('4K60 required');
          }
        }
        result['loadOutcome'] = 'observedReadyPlayingAndFramePresented';
        result['routeToReadyMs'] = readyWatch.elapsedMilliseconds;
        final startPosition = player.positionInMilliseconds;
        result['sourceSize'] = {
          'width': player.videoPlayerController?.state.width,
          'height': player.videoPlayerController?.state.height,
        };
        result['decoder'] = player.videoPlayerController?.getProperty(
          'hwdec-current',
        );
        final playing = await record('round$round:playing');
        frames.clear();
        measuringFrames = true;
        await Future<void>.delayed(Duration(seconds: playSeconds));
        measuringFrames = false;
        result['playingFrames'] = frameSummary();
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
        await record('round$round:settingIdleBeforeOptimization');
        if (optimizeIdleHeaps) result['heapOptimization'] = heap.optimize();
        // 对照组也等待同样时间，区分自然回落与显式整理。
        await Future<void>.delayed(const Duration(seconds: 3));
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
            actuallyPlayed &&
            result['nativeOutputObserved'] == true &&
            (!browseExercise || result['browsePassed'] == true);
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
    if (exerciseWebView) {
      await record('beforeFirstWebView');
      const html =
          '<!doctype html><html><head><title>PiliAurora memory probe</title></head>'
          '<body style="background:linear-gradient(135deg,#123456,#abcdee);height:100vh">'
          '<h1>PiliAurora memory probe</h1><p>Local deterministic page</p></body></html>';
      for (var visit = 1; visit <= 2; visit++) {
        final loaded = Completer<void>();
        final open = Stopwatch()..start();
        final closed = Get.to<void>(
          () => Scaffold(
            body: WebViewReady(
              prepare: () async {
                if (!await LoginUtils.setWebCookie()) {
                  throw StateError('Web account changed');
                }
              },
              builder: (_) => web.InAppWebView(
                webViewEnvironment: AppWebViewEnvironment.instance,
                initialData: web.InAppWebViewInitialData(data: html),
                onLoadStop: (controller, _) async {
                  try {
                    final title = await controller.evaluateJavascript(
                      source: 'document.title',
                    );
                    report['webDomTitleMatched'] =
                        title == 'PiliAurora memory probe';
                    // 初始 about:blank 也可能先发 LoadStop，等待本地 HTML 自己完成。
                    if (title != 'PiliAurora memory probe') return;
                    if (!loaded.isCompleted) loaded.complete();
                  } catch (error, stack) {
                    if (!loaded.isCompleted) loaded.completeError(error, stack);
                  }
                },
              ),
            ),
          ),
        );
        await loaded.future.timeout(const Duration(seconds: 30));
        final expectedCookies = Accounts.main.cookieJar.toList();
        // 浏览响应仍可能更新匿名设备 Cookie；先同步本次快照再读取，不比较过期时点。
        await LoginUtils.setWebCookie();
        final webCookies = web.CookieManager.instance(
          webViewEnvironment: AppWebViewEnvironment.instance,
        );
        final actualCookies = (await Future.wait(
          expectedCookies.map(
            (cookie) => webCookies.getCookies(
              url: web.WebUri(
                'https://${(cookie.domain ?? 'bilibili.com').replaceFirst(RegExp(r'^\.'), '')}${cookie.path ?? '/'}',
              ),
            ),
          ),
        )).expand((cookies) => cookies).toList();
        final cookiesPassed = expectedCookies.every(
          (expected) => actualCookies.any(
            (actual) =>
                actual.name == expected.name && actual.value == expected.value,
          ),
        );
        report['webCookieValidation'] = {
          'expectedCount': expectedCookies.length,
          'actualCount': actualCookies.length,
          'unmatchedNames': expectedCookies
              .where(
                (expected) => !actualCookies.any(
                  (actual) =>
                      actual.name == expected.name &&
                      actual.value == expected.value,
                ),
              )
              .map((cookie) => cookie.name)
              .toList(),
        };
        if (!cookiesPassed) {
          throw StateError('Native web cookies do not match current account');
        }
        report['webViewVisit$visit'] = {
          'pageLoadMs': open.elapsedMilliseconds,
          'scope': 'productionEnvironmentAndReadinessWidget; localHtml; notWebviewPageUrlNavigation',
          'domTitleVerified': true,
          'environmentReady': AppWebViewEnvironment.instance != null,
          'cookieValuesMatched': cookiesPassed,
          'expectedCookieCount': expectedCookies.length,
        };
        await Future<void>.delayed(const Duration(seconds: 3));
        await record('webView$visit:loaded');
        Get.back<void>();
        await closed;
        await Future<void>.delayed(Duration(seconds: idleSeconds));
        await record('webView$visit:closedIdle');
        report['webViewVisit${visit}EnvironmentReleased'] =
            AppWebViewEnvironment.instance == null;
        if (!retainWebView && AppWebViewEnvironment.instance != null) {
          throw StateError('Idle WebView environment retained');
        }
      }
    }
    report['validWorkload'] =
        rounds.length == (webViewOnly ? 0 : 2) &&
        (!webViewOnly || report['webViewVisit2'] != null) &&
        rounds.every((round) => round['validWorkload'] == true);
    report['passed'] =
        report['validWorkload'] == true &&
        rounds.every((round) => round['passed'] == true);
    report['state'] = 'completed';
  } catch (error) {
    report['state'] = 'failed';
    report['errorType'] = error.runtimeType.toString();
    if (error is StateError &&
        const {
          'Web account changed',
          'Native web cookies do not match current account',
        }.contains(error.message)) {
      report['probeFailure'] = error.message;
    }
  } finally {
    releaseWebControl?.call();
    WidgetsBinding.instance.removeTimingsCallback(onTimings);
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
