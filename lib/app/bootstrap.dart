import 'dart:async' show unawaited;
import 'dart:io';

import 'package:pili_aurora/plugin/pl_player/playback/presentation_profile.dart';

import 'package:pili_aurora/app/app.dart';
import 'package:pili_aurora/app/app_paths.dart';
import 'package:pili_aurora/app/platform_setup.dart';
import 'package:pili_aurora/app/startup.dart';
import 'package:pili_aurora/app/startup_failure.dart';
import 'package:pili_aurora/services/desktop_playback_windows.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart'
    show PlaybackShutdownOutcome;
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/build_config.dart';
import 'package:pili_aurora/common/widgets/scale_app.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/services/account_service.dart';
import 'package:pili_aurora/services/app_icon.dart';
import 'package:pili_aurora/services/download/download_repository.dart';
import 'package:pili_aurora/services/download/download_service.dart';
import 'package:pili_aurora/services/logger.dart';
import 'package:pili_aurora/utils/cache_manager.dart';
import 'package:pili_aurora/utils/date_utils.dart';
import 'package:pili_aurora/utils/font_utils.dart';
import 'package:pili_aurora/services/diagnostics/report_handler.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/request_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/theme_utils.dart';
import 'package:catcher_2/catcher_2.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';

/// 初始化本地资源和平台服务，配置异常捕获后挂载应用根 Widget。
Future<StartupResult> bootstrapApplication([
  List<String> arguments = const [],
]) async {
  final progress = StartupProgress();
  final result = await progress.run(
    () => _bootstrapApplication(arguments, progress),
  );
  if (result is StartupFailure) {
    exitCode = 1;
    logger.e(
      '应用启动失败：${result.phase.label}',
      error: result.cause.runtimeType,
      stackTrace: result.stackTrace,
    );
    final playerWindow =
        Platform.isWindows &&
        arguments.firstOrNull == DesktopPlaybackWindows.argument;
    if (playerWindow) {
      try {
        DesktopPlaybackWindows.instance.playerFailed();
      } catch (error, stackTrace) {
        logger.w('通知主窗口失败', error: error.runtimeType, stackTrace: stackTrace);
      }
    }
    try {
      await Diagnostics.instance.flush().timeout(const Duration(seconds: 2));
    } catch (error, stackTrace) {
      logger.w(
        '启动失败后的日志刷新未完成',
        error: error.runtimeType,
        stackTrace: stackTrace,
      );
    }
    if (playerWindow) exit(1);
    try {
      await showStartupFailure(result);
    } catch (error, stackTrace) {
      logger.e('启动错误页显示失败', error: error.runtimeType, stackTrace: stackTrace);
      Error.throwWithStackTrace(result, result.stackTrace);
    }
  }
  return result;
}

Future<void> _bootstrapApplication(
  List<String> arguments,
  StartupProgress progress,
) async {
  initializePresentationEngineConfiguration();
  ScaledWidgetsFlutterBinding.ensureInitialized();
  progress.phase = StartupPhase.supportPath;
  await initializeSupportPath();
  final windows = DesktopPlaybackWindows.instance;
  final playerWindow =
      Platform.isWindows &&
      arguments.firstOrNull == DesktopPlaybackWindows.argument;
  progress.phase = StartupPhase.diagnostics;
  await LoggerUtils.prepare(
    windowId: playerWindow
        ? int.parse(Platform.environment['PILIAURORA_WINDOW_ID']!)
        : null,
  );
  if (!playerWindow) {
    Diagnostics.instance
      ..onSettingsChanged = windows.syncDiagnosticSettings
      ..pauseChildren = windows.pauseWindowDiagnostics
      ..clearChildren = windows.clearWindowDiagnostics
      ..resumeChildren = windows.resumeWindowDiagnostics;
  }
  progress.phase = StartupPhase.playerConnection;
  final initialization = playerWindow ? await windows.connectPlayer() : null;
  if (playerWindow) {
    Diagnostics.instance.forwardRecord = windows.sendDiagnosticRecord;
    Diagnostics.instance.forwardFlush = windows.flushDiagnostics;
  }
  progress.phase = StartupPhase.engine;
  MediaKit.ensureInitialized();
  progress.phase = StartupPhase.storage;
  await GStorage.init(memorySnapshot: initialization?.storage);
  AppIcon.load();
  try {
    await AppIcon.syncLauncher();
  } catch (error, stack) {
    logger.w('同步桌面图标失败', error: error.runtimeType, stackTrace: stack);
  }
  if (playerWindow) {
    await GStorage.setting.putAll({
      SettingBoxKey.desktopVolume: ?windows.initialVolume,
      SettingBoxKey.autoPlayEnable: true,
      SettingBoxKey.enableAutoEnter: false,
      SettingBoxKey.preInitPlayer: false,
      SettingBoxKey.showVideoReply: false,
      SettingBoxKey.showBangumiReply: false,
      SettingBoxKey.showRelatedVideo: false,
      SettingBoxKey.pageTransition: Transition.noTransition.index,
    });
  }
  ScaledWidgetsFlutterBinding.instance.scaleFactor = Pref.uiScale;
  progress.phase = StartupPhase.diagnostics;
  await LoggerUtils.initialize();
  if (playerWindow) await windows.applyDiagnosticSettings();
  progress.phase = StartupPhase.resources;
  await Future.wait([
    initializeDownloadPath(),
    initializeTemporaryPath(),
    CacheManager.ensureInitialized(directory: windows.cacheDirectory),
    ?FontUtils.init(),
  ]);
  Get
    ..lazyPut(AccountService.new)
    ..lazyPut(
      () => DownloadService(
        repository: DownloadRepository(
          rootPath: () => downloadPath,
          onReadError: (path, error, stackTrace) => logger.w(
            '下载元数据读取或恢复异常: $path',
            error: error,
            stackTrace: stackTrace,
          ),
        ),
        downloadClient: Request.http11Dio,
      ),
    );
  HttpOverrides.global = _CustomHttpOverrides();
  if (Pref.badCertificateCallback) {
    logger.w('已显式禁用 TLS 证书验证，仅应用于受控调试；请在调试结束后恢复验证');
  }

  // Windows Cookie 同步依赖 WebView 环境，因此先完成平台服务初始化。
  progress.phase = StartupPhase.platformServices;
  if (!playerWindow) await initializePlatformServices();

  progress.phase = StartupPhase.requests;
  Request();
  Request.setCookie(syncWebView: !playerWindow);
  if (!playerWindow) {
    unawaited(
      RequestUtils.syncHistoryStatus().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        logger.w(
          '启动历史状态同步失败',
          error: error.runtimeType,
          stackTrace: stackTrace,
        );
      }),
    );
  }
  windows.setLocalMuted = (muted) async {
    await PlPlayerController.instance?.setMuted(muted);
  };

  SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);

  progress.phase = StartupPhase.window;
  await initializePlatformWindow();
  if (playerWindow) {
    await windows.watchPlayerWindow();
    windows.onPlayerClose = () async {
      final controller = PlPlayerController.instance;
      if (controller?.videoPlayerController != null &&
          controller!.isFileSource &&
          controller.cid != null) {
        windows.savePlaybackProgress(
          controller.cid!,
          controller.positionInMilliseconds,
        );
      }
      final shutdown = await controller?.shutdownPlaybackFacade();
      final directory = windows.cacheDirectory!;
      Future<void> cleanupWindowResources() async {
        await CacheManager.manager.dispose();
        await GStorage.close();
        if (directory.existsSync()) await directory.delete(recursive: true);
      }

      if (shutdown?.outcome == PlaybackShutdownOutcome.cleanupIncomplete) {
        logger.w('播放器在关闭时未能于预算内完成清理', error: shutdown?.failure);
        try {
          await controller!.playbackReleased.timeout(
            const Duration(seconds: 3),
          );
          await cleanupWindowResources();
        } catch (error, stackTrace) {
          logger.e('播放器延迟清理未完成，窗口结束清理等待', error: error, stackTrace: stackTrace);
        }
        return;
      }
      if (controller != null) await controller.playbackReleased;
      await cleanupWindowResources();
    };
  }

  progress.phase = StartupPhase.application;
  if (Pref.dynamicColor) {
    await ThemeUtils.initPlatformState();
  }

  // 始终安装异常捕获，日志等级可即时切换。
  final customParameters = {
    'Build Time': DateFormatUtils.format(
      BuildConfig.buildTime,
      format: DateFormatUtils.longFormatDs,
    ),
    'Commit Hash': BuildConfig.commitHash,
    'MPV Api Version':
        '${NativePlayer.apiVersion >> 16}.${NativePlayer.apiVersion & 0xFFFF}',
  };

  Catcher2(
    [DiagnosticReportHandler()],
    PiliAuroraApp(playbackRequest: initialization?.request),
    logger: (level, message, {error, stackTrace}) {
      final log = switch (level) {
        ReportLogLevel.debug => logger.d,
        ReportLogLevel.info => logger.i,
        ReportLogLevel.warning => logger.w,
        ReportLogLevel.error => logger.e,
      };
      log(message, error: error, stackTrace: stackTrace);
    },
    customParameters: customParameters,
  );
  if (!playerWindow) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final diagnostics = Diagnostics.instance;
      if (shouldWarnAboutDiagnosticRecording(
        tracing: diagnostics.tracing,
        level: diagnostics.level,
        playerLevel: diagnostics.playerLevel,
      )) {
        SmartDialog.showToast(
          '性能记录或详细日志已启用，如不需要，请关闭并清理',
          displayTime: const Duration(seconds: 5),
        );
      }
    });
  }
}

class _CustomHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    // ..maxConnectionsPerHost = 32
    /// The default value is 15 seconds.
    //   ..idleTimeout = const Duration(seconds: 15);
    if (Pref.badCertificateCallback) {
      client.badCertificateCallback = (cert, host, port) => true;
    }
    return client;
  }
}
