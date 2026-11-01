import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pili_aurora/app/bootstrap.dart';
import 'package:pili_aurora/common/widgets/scale_app.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_playback_runtime.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/plugin/pl_player/playback/presentation_profile.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:window_manager/window_manager.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String> getTemporaryPath() async => '$root/temp';
  @override
  Future<String> getApplicationSupportPath() async => '$root/support';
  @override
  Future<String> getApplicationDocumentsPath() async => '$root/documents';
  @override
  Future<String> getDownloadsPath() async => '$root/downloads';
}

/// 所有测量和报告写入结束后，先释放页面持有的托盘等原生句柄，再销毁引擎。
Future<void> closeProbeWindow() async {
  final treeDisposed = Completer<void>();
  runApp(
    Builder(
      builder: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!treeDisposed.isCompleted) treeDisposed.complete();
        });
        return const SizedBox.shrink();
      },
    ),
  );
  await treeDisposed.future.timeout(const Duration(seconds: 10));
  await windowManager.destroy();
}

/// 独立目录的人工复现入口；--smoke 仅播放本地样片并验证诊断接线。
Future<void> main(List<String> arguments) async {
  final root =
      Platform.environment['PILIAURORA_MEMORY_ROOT'] ??
      '${File(Platform.resolvedExecutable).parent.path}/memory-data';
  for (final name in ['temp', 'support', 'documents', 'downloads']) {
    await Directory('$root/$name').create(recursive: true);
  }
  PathProviderPlatform.instance = _Paths(root);
  ScaledWidgetsFlutterBinding.ensureInitialized();
  if (!arguments.contains('--smoke')) {
    await bootstrapApplication(arguments);
    await Diagnostics.instance.configure(
      tracing: true,
      intervalMs: 1000,
      playerLevel: DiagnosticLogLevel.info,
    );
    return;
  }
  initializePresentationEngineConfiguration();
  await windowManager.ensureInitialized();
  MediaKit.ensureInitialized();
  final media = Platform.environment['PILIAURORA_MEMORY_MEDIA'];
  if (media == null || !File(media).existsSync()) {
    throw ArgumentError('PILIAURORA_MEMORY_MEDIA 需要指向本地样片');
  }
  final diagnostics = Diagnostics.instance;
  await diagnostics.initialize(
    directory: Directory('$root/support/diagnostics'),
  );
  await diagnostics.configure(tracing: true);
  runApp(const MaterialApp(home: ColoredBox(color: Colors.black)));
  final runtime = NativePlaybackRuntime(
    configuration: PlaybackRuntimeConfig(
      playerOptions: const {'ao': 'null'},
      hardwareAccelerationEnabled: true,
      hardwareDecoder: 'auto-safe',
    ),
    diagnosticsExtra: () => const {},
  );
  final session = PlaybackSession(runtime: runtime);
  final owner = session.attach();
  final report = <String, Object?>{};
  final attach = Timer.periodic(const Duration(milliseconds: 20), (timer) {
    final video = runtime.videoController;
    if (video == null) return;
    runApp(
      MaterialApp(
        home: Center(child: SimpleVideo(controller: video)),
      ),
    );
    timer.cancel();
  });
  try {
    final load = await owner
        .load(
          PlaybackPlan(
            contentKey: 'memory-logging-local-fixture',
            source: PlaybackSourceSnapshot.fromDataSource(
              NetworkSource(videoSource: media, audioSource: null),
            ),
            timeline: const PlaybackTimeline(
              kind: PlaybackTimelineKind.onDemand,
              seekPolicy: PlaybackSeekPolicy.allowed,
            ),
            configuration: PlaybackConfiguration(),
          ),
          start: PlaybackStartPolicy.play,
        )
        .timeout(const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(seconds: 6));
    diagnostics.capture();
    report['loaded'] = load.outcome.name;
    report['duringPlayback'] = diagnostics.latest;
  } catch (error) {
    report['errorType'] = error.runtimeType.toString();
  } finally {
    attach.cancel();
    owner.close();
    final shutdown = await session.shutdown().timeout(
      const Duration(seconds: 20),
    );
    report['shutdown'] = shutdown.outcome.name;
  }
  runApp(const MaterialApp(home: ColoredBox(color: Colors.black)));
  await Future<void>.delayed(const Duration(seconds: 6));
  diagnostics.capture();
  report['afterPlayback'] = diagnostics.latest;
  final during = report['duringPlayback'] as Map?;
  final duringResources =
      (during?['nativeMemory'] as Map?)?['resources'] as Map?;
  final after = diagnostics.latest?['nativeMemory'] as Map?;
  final afterResources = after?['resources'] as Map?;
  report['passed'] =
      report['loaded'] == 'ready' &&
      report['shutdown'] == 'released' &&
      (during?['memory'] as Map?)?['status'] == 'sampled' &&
      ((duringResources?['videoOutput'] as Map?)?['count'] as int? ?? 0) > 0 &&
      afterResources != null &&
      afterResources.values.every((value) => (value as Map)['count'] == 0) &&
      after?['pendingTextureUnregistrations'] == 0 &&
      after?['releasingOutputs'] == 0;
  await diagnostics.configure(tracing: false);
  await diagnostics.flush();
  await File('$root/smoke.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
  );
  diagnostics.dispose();
  // 走平台窗口销毁，让 runner 在平台线程释放插件和 COM 资源。
  await windowManager.destroy();
}
