import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart'
    show Element, RenderObjectElement, TickerMode, WidgetsBinding;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/animation.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:pili_aurora/models/common/home_tab_type.dart';
import 'package:pili_aurora/common/widgets/inactive_feed_sliver.dart';
import 'package:pili_aurora/models/common/nav_bar_config.dart';
import 'package:pili_aurora/pages/common/common_controller.dart';
import 'package:pili_aurora/pages/dynamics/controller.dart';
import 'package:pili_aurora/pages/home/controller.dart';
import 'package:pili_aurora/pages/main/controller.dart';
import 'package:pili_aurora/pages/mine/controller.dart';
import 'package:pili_aurora/pages/rank/controller.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/process_metrics.dart';

import 'memory_logging.dart' as logging;
import 'process_heap_memory.dart';

const _channel = MethodChannel(
  'pili_aurora/graphics_memory',
  JSONMethodCodec(),
);
const _vmChannel = MethodChannel('pili_aurora/vm_memory', JSONMethodCodec());
const _cpuChannel = MethodChannel('pili_aurora/cpu_memory', JSONMethodCodec());

Future<Map<String, Object?>> _cpu([String action = 'sample']) async {
  try {
    return await _cpuChannel
            .invokeMapMethod<String, Object?>(action)
            .timeout(const Duration(seconds: 10)) ??
        const {'status': 'empty'};
  } on MissingPluginException {
    return const {'status': 'unsupported'};
  } catch (error) {
    return {'status': 'error', 'errorType': error.runtimeType.toString()};
  }
}

Future<Map<String, Object?>> _vm([String method = 'vmSample']) async {
  try {
    return await _vmChannel
            .invokeMapMethod<String, Object?>(method)
            .timeout(const Duration(seconds: 20)) ??
        const {'status': 'empty'};
  } on MissingPluginException {
    return const {'status': 'unsupported'};
  } catch (error) {
    return {'status': 'error', 'errorType': error.runtimeType.toString()};
  }
}

const _deviceChannel = MethodChannel(
  'pili_aurora/graphics_device',
  JSONMethodCodec(),
);

Future<Map<String, Object?>> _device() async {
  try {
    return await _deviceChannel
            .invokeMapMethod<String, Object?>('sample')
            .timeout(const Duration(seconds: 10)) ??
        const {'status': 'empty'};
  } on MissingPluginException {
    return const {'status': 'unsupported'};
  } catch (error) {
    return {'status': 'error', 'errorType': error.runtimeType.toString()};
  }
}

int _seconds(String name, int fallback) =>
    (int.tryParse(Platform.environment[name] ?? '') ?? fallback).clamp(1, 600);

Map<String, Object> _uiCounts() {
  var elements = 0;
  var renderObjects = 0;
  var paragraphs = 0;
  var activeFeeds = 0;
  var inactiveFeeds = 0;
  final cards = <String, int>{};
  const names = {
    'VideoCardV',
    'VideoCardH',
    'PgcCardVPgcIndex',
    'LiveCardVApp',
    'PgcRankItem',
    'PgcCardVTimeline',
  };
  void visit(Element element) {
    elements++;
    if (element is RenderObjectElement) {
      renderObjects++;
      if (element.renderObject is RenderParagraph) paragraphs++;
    }
    final widget = element.widget;
    final name = widget.runtimeType.toString();
    if (names.contains(name)) {
      cards.update(name, (value) => value + 1, ifAbsent: () => 1);
    }
    if (widget is InactiveFeedSliver) {
      if (TickerMode.getValuesNotifier(element).value.enabled) {
        activeFeeds++;
      } else {
        inactiveFeeds++;
      }
    }
    element.visitChildren(visit);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root != null) visit(root);
  return {
    'elements': elements,
    'renderObjects': renderObjects,
    'paragraphs': paragraphs,
    'activeFeeds': activeFeeds,
    'inactiveFeeds': inactiveFeeds,
    'cards': cards,
    'semantics': 'probeStageTraversalOnly; retainsNoElementReferences',
  };
}

/// 真实浏览负载。--browse-only 保留无 clear/purge 干预的基线。
Future<void> main(List<String> arguments) async {
  final browseOnly = arguments.contains('--browse-only');
  final detailedStages =
      Platform.environment['PILIAURORA_BROWSING_DETAILS'] != 'false';
  final actions = browseOnly
      ? <String>[]
      : (Platform.environment['PILIAURORA_BROWSING_ACTIONS'] ??
                'trim,clearImages,frame,purgeRasterCache,purgeRaster,purgeIO,flushIO,flushRaster,trim')
            .split(',')
            .map((action) => action.trim())
            .where((action) => action.isNotEmpty)
            .toList();
  final dwell = _seconds('PILIAURORA_BROWSING_DWELL_SECONDS', 8);
  final idle = _seconds('PILIAURORA_BROWSING_IDLE_SECONDS', 70);
  final control = _seconds('PILIAURORA_BROWSING_CONTROL_SECONDS', 8);
  final settle = _seconds('PILIAURORA_BROWSING_SETTLE_SECONDS', 60);
  final output = File(
    Platform.environment['PILIAURORA_BROWSING_OUTPUT'] ??
        '${File(Platform.resolvedExecutable).parent.path}/browsing-probe.json',
  );
  final clock = Stopwatch()..start();
  final visits = <Map<String, Object?>>[];
  final stages = <Map<String, Object?>>[];
  final controllerIdentities = <String, int>{};
  final scrollOffsets = <String, double>{};
  final report = <String, Object?>{
    'schemaVersion': 1,
    'state': 'running',
    'browseOnly': browseOnly,
    'detailedStageSnapshots': detailedStages,
    'actions': actions,
    'contextBytesSemantics':
        'rasterAndIOCanShareDuplicatedBacking; notUniqueGpuBytes',
    'scope': 'baselineSettingIdleIsUnmodified; laterControlsAreDiagnosticInterventions',
    'shutdownPolicy': 'unmountWidgetsAfterFinalSnapshotThenDestroyHost',
    'validWorkload': false,
    'durationsSeconds': {
      'dwell': dwell,
      'idle': idle,
      'control': control,
      'settle': settle,
    },
    'visits': visits,
    'stages': stages,
  };
  final diagnostics = Diagnostics.instance;
  final process = ProcessMetrics();
  final processHeap = ProcessHeapMemory();
  Future<void> progress() async {
    await output.parent.create(recursive: true);
    await File('${output.parent.path}/progress.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        ...report,
        // 完整历史只在结束时写一次，避免每个检查点重编累计的大字符串。
        'stages': stages.isEmpty ? const [] : [stages.last],
        'stageCount': stages.length,
        'finalReport': report['state'] != 'running',
      }),
    );
  }

  Future<Map<String, Object?>> native({
    String? context,
    bool freeGpuResources = false,
  }) async {
    try {
      return await _channel
              .invokeMapMethod<String, Object?>(
                context == null
                    ? 'sample'
                    : freeGpuResources
                    ? 'freeGpuResources'
                    : 'purge',
                context == null ? {'resources': true} : {'context': context},
              )
              .timeout(const Duration(seconds: 10)) ??
          const {'status': 'empty'};
    } on MissingPluginException {
      return const {'status': 'unsupported'};
    } catch (error) {
      return {'status': 'error', 'errorType': error.runtimeType.toString()};
    }
  }

  Future<void> record(
    String name,
    String action, {
    Map<String, Object?>? receipt,
  }) async {
    if (detailedStages) diagnostics.capture();
    stages.add({
      'stage': name, 'action': action,
      'elapsedMs': clock.elapsedMilliseconds,
      'time': DateTime.now().toUtc().toIso8601String(),
      'observedProcess': process.sample(),
      'processHeap': processHeap.sample(),
      // latest 已经由 Diagnostics 脱敏，深复制避免后续capture改变历史。
      'diagnostics': !detailedStages || diagnostics.latest == null
          ? null
          : jsonDecode(jsonEncode(diagnostics.latest)),
      if (detailedStages) ...{
        'native': await native(),
        'vm': await _vm(),
        'cpu': await _cpu(),
        'device': await _device(),
        'ui': _uiCounts(),
      },
      'images': {
        'cacheBytes': PaintingBinding.instance.imageCache.currentSizeBytes,
        'cacheEntries': PaintingBinding.instance.imageCache.currentSize,
        'liveImages': PaintingBinding.instance.imageCache.liveImageCount,
        'pendingImages': PaintingBinding.instance.imageCache.pendingImageCount,
      },
      'receipt': ?receipt,
      'views': [
        for (final view in ui.PlatformDispatcher.instance.views)
          {
            'physicalWidth': view.physicalSize.width,
            'physicalHeight': view.physicalSize.height,
            'devicePixelRatio': view.devicePixelRatio,
          },
      ],
    });
    await progress();
  }

  Future<void> visit(
    String name,
    ScrollOrRefreshMixin? Function() find, {
    bool requireItems = false,
  }) async {
    await Future<void>.delayed(Duration(seconds: dwell));
    final entry = <String, Object?>{
      'tab': name,
      'elapsedMs': clock.elapsedMilliseconds,
    };
    try {
      final controller = find();
      if (controller == null) throw StateError('controller unavailable');
      controllerIdentities[name] = identityHashCode(controller);
      final stateController = controller is RankController
          ? controller.controller
          : controller;
      if (stateController is CommonController) {
        final state = stateController.loadingState.value;
        final data = state.dataOrNull;
        final items = data is List ? data.length : null;
        entry.addAll({
          'state': state.isSuccess ? 'success' : state.runtimeType.toString(),
          'items': items,
          'loaded': state.isSuccess && (!requireItems || (items ?? 0) > 0),
        });
      } else {
        entry['loaded'] = false;
      }
      final scroll = controller.scrollController;
      if (scroll.hasClients && scroll.positions.length == 1) {
        final position = scroll.position;
        final target = math.min(
          position.maxScrollExtent,
          position.pixels + position.viewportDimension * 0.85,
        );
        if (target > position.pixels) {
          await scroll
              .animateTo(
                target,
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOut,
              )
              .timeout(const Duration(seconds: 3));
          entry['scrolledPixels'] = target;
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        scrollOffsets[name] = position.pixels;
      }
    } catch (error) {
      entry.addAll({
        'loaded': false,
        'errorType': error.runtimeType.toString(),
      });
    }
    visits.add(entry);
    await record('visit:$name', 'switchTabAndAtMostOneScreenScroll');
  }

  try {
    await logging
        .main(
          arguments
              .where((arg) => arg != '--smoke' && arg != '--browse-only')
              .toList(),
        )
        .timeout(const Duration(seconds: 90));
    final ready = Stopwatch()..start();
    while (!Get.isRegistered<MainController>() ||
        !Get.isRegistered<HomeController>() ||
        SmartDialog.checkExist()) {
      if (ready.elapsed > const Duration(seconds: 45)) {
        throw TimeoutException(
          'startup not ready or startup dialog still open',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final main = Get.find<MainController>();
    final home = Get.find<HomeController>();
    void select(NavigationBarType tab) {
      final index = main.navigationBars.indexOf(tab);
      if (index < 0) throw StateError('navigation tab unavailable');
      // 再次选择当前tab会触发刷新；探针只做页面切换。
      if (main.selectedIndex.value != index) main.setIndex(index);
    }

    select(NavigationBarType.home);
    for (final tab in const [
      HomeTabType.rcmd,
      HomeTabType.hot,
      HomeTabType.rank,
      HomeTabType.bangumi,
      HomeTabType.cinema,
      HomeTabType.live,
    ]) {
      final index = home.tabs.indexOf(tab);
      if (index < 0) {
        visits.add({
          'tab': tab.name,
          'loaded': false,
          'state': 'notConfigured',
        });
        continue;
      }
      if (home.tabController.index != index) {
        home.tabController.animateTo(index);
      }
      await visit(tab.name, () => home.controller, requireItems: true);
    }
    select(NavigationBarType.dynamics);
    await visit(
      'dynamics',
      () => Get.find<DynamicsController>().controller,
      requireItems: true,
    );
    select(NavigationBarType.mine);
    await visit('mine', Get.find<MineController>);
    report['validWorkload'] =
        visits.length == 8 && visits.every((entry) => entry['loaded'] == true);
    // 不await路由Future：它在设置页pop时才结束。
    unawaited(Get.toNamed<void>('/setting'));
    await Future<void>.delayed(Duration(seconds: idle));
    await record(
      'baselineSettingIdle',
      'settingIdleWithoutCacheOrPurgeIntervention',
    );
    report['settingRouteReached'] = Get.currentRoute == '/setting';
    if (Get.currentRoute != '/setting') report['validWorkload'] = false;
    final memory = stages.last['observedProcess'] as Map?;
    final privateBytes = memory?['privateBytes'] as num?;
    final rssBytes = memory?['rssBytes'] as num?;
    report['baselineRetentionTarget'] = {
      'limitBytes': 500 * 1024 * 1024,
      'measurementSource': 'observedProcess',
      'privateBytes': privateBytes,
      'rssBytes': rssBytes,
      'passed':
          report['validWorkload'] == true &&
          privateBytes != null &&
          rssBytes != null &&
          privateBytes < 500 * 1024 * 1024 &&
          rssBytes < 500 * 1024 * 1024,
    };
    if (!browseOnly) {
      for (final (index, action) in actions.indexed) {
        Map<String, Object?> receipt;
        if (action == 'sampleHeaps') {
          receipt = processHeap.sample();
        } else if (action == 'sampleCPU' ||
            action == 'purgeCPUResources' ||
            action == 'purgeCPUFonts' ||
            action == 'purgeCPUHarfBuzz') {
          receipt = await _cpu(
            const {
              'sampleCPU': 'sample',
              'purgeCPUResources': 'purgeResource',
              'purgeCPUFonts': 'purgeFont',
              'purgeCPUHarfBuzz': 'purgeHarfBuzz',
            }[action]!,
          );
        } else if (action == 'freeGpuRaster' || action == 'freeGpuIO') {
          receipt = await native(
            context: action == 'freeGpuRaster' ? 'raster' : 'io',
            freeGpuResources: true,
          );
        } else if (action == 'optimizeHeaps') {
          receipt = processHeap.optimize();
        } else if (action == 'stopDiagnostics') {
          await diagnostics.configure(tracing: false);
          receipt = const {'status': 'performanceRecordingStopped'};
        } else if (action == 'trim') {
          try {
            receipt =
                await _deviceChannel
                    .invokeMapMethod<String, Object?>('trim')
                    .timeout(const Duration(seconds: 10)) ??
                const {'status': 'empty'};
          } on MissingPluginException {
            receipt = const {'status': 'unsupported'};
          } catch (error) {
            receipt = {
              'status': 'error',
              'errorType': error.runtimeType.toString(),
            };
          }
        } else if (action == 'resumeRcmd') {
          if (Get.currentRoute != '/setting') {
            throw StateError('resume expects retained settings route');
          }
          Get.back<void>();
          select(NavigationBarType.home);
          final index = home.tabs.indexOf(HomeTabType.rcmd);
          if (index < 0) throw StateError('recommend tab unavailable');
          if (home.tabController.index != index) {
            home.tabController.animateTo(index);
          }
          await Future<void>.delayed(Duration(seconds: dwell));
          final controller = home.controller;
          final scroll = controller.scrollController;
          final expected = scrollOffsets[HomeTabType.rcmd.name];
          final actual = scroll.hasClients && scroll.positions.length == 1
              ? scroll.position.pixels
              : null;
          final sameController =
              identityHashCode(controller) ==
              controllerIdentities[HomeTabType.rcmd.name];
          final offsetPreserved =
              expected != null &&
              actual != null &&
              (expected - actual).abs() < 0.5;
          final loaded =
              controller is CommonController &&
              controller.loadingState.value.isSuccess;
          receipt = {
            'status': 'resumed',
            'sameController': sameController,
            'expectedScrollOffset': expected,
            'actualScrollOffset': actual,
            'offsetPreserved': offsetPreserved,
            'loaded': loaded,
            'passed': sameController && offsetPreserved && loaded,
          };
          report['resumeValidation'] = receipt;
        } else if (action == 'settingIdle') {
          if (Get.currentRoute != '/setting') {
            unawaited(Get.toNamed<void>('/setting'));
          }
          await Future<void>.delayed(Duration(seconds: idle));
          receipt = {
            'status': 'settingIdle',
            'settingRouteReached': Get.currentRoute == '/setting',
            'idleSeconds': idle,
          };
        } else if (action == 'collectDart' || action == 'collectDartFull') {
          receipt = await _vm(action);
        } else if (RegExp(r'^cache\d+$').hasMatch(action)) {
          final cache = PaintingBinding.instance.imageCache;
          final before = cache.maximumSizeBytes;
          cache.maximumSizeBytes = int.parse(action.substring(5)) * 1024 * 1024;
          receipt = {
            'status': 'cacheLimitChanged',
            'before': before,
            'after': cache.maximumSizeBytes,
            'currentSize': cache.currentSize,
            'currentSizeBytes': cache.currentSizeBytes,
          };
        } else if (action == 'dropMainRoute') {
          // 仅用于归因：销毁保活页面后对照原生资源，不能作为产品回收策略。
          unawaited(Get.offAllNamed<void>('/setting'));
          receipt = const {'status': 'routeReplacementRequested'};
        } else if (action == 'frame') {
          WidgetsBinding.instance.scheduleFrame();
          var complete = true;
          try {
            await WidgetsBinding.instance.endOfFrame.timeout(
              const Duration(seconds: 3),
            );
          } on TimeoutException {
            complete = false;
          }
          receipt = {'status': 'frameRequested', 'complete': complete};
        } else if (action == 'clearImages') {
          PaintingBinding.instance.imageCache.clear();
          receipt = const {'status': 'cleared', 'clearLiveImages': false};
        } else {
          final context = const {
            'purgeRaster': 'raster',
            'purgeIO': 'io',
            'purgeRasterCache': 'rasterCache',
            'flushIO': 'flushIO',
            'flushRaster': 'flushRaster',
          }[action];
          if (context == null) throw ArgumentError.value(action, 'action');
          receipt = await native(context: context);
        }
        await Future<void>.delayed(Duration(seconds: control));
        await record('action${index + 1}:$action', action, receipt: receipt);
      }
      await Future<void>.delayed(Duration(seconds: settle));
      await record('settled', 'idleAfterDiagnosticInterventions');
    }
  } catch (error) {
    report['state'] = 'failed';
    report['errorType'] = error.runtimeType.toString();
    if (error is FileSystemException) report['error'] = error.toString();
    report['validWorkload'] = false;
  } finally {
    report['elapsedMs'] = clock.elapsedMilliseconds;
    try {
      await record('finalSnapshot', 'finalReadOnlySnapshot');
      await diagnostics.flush().timeout(const Duration(seconds: 15));
    } catch (error) {
      report['state'] = 'failed';
      report['flushErrorType'] = error.runtimeType.toString();
    }
    try {
      if (report['state'] == 'running') report['state'] = 'completed';
      await output.parent.create(recursive: true);
      await output.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
      await progress();
    } finally {
      await logging.closeProbeWindow();
    }
  }
}
