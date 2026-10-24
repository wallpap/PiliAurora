import 'dart:io';

import 'package:pili_aurora/plugin/pl_player/playback/presentation_profile.dart';

import 'package:pili_aurora/app/app.dart';
import 'package:pili_aurora/app/app_paths.dart';
import 'package:pili_aurora/app/platform_setup.dart';
import 'package:pili_aurora/services/desktop_playback_windows.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart'
    show PlaybackShutdownOutcome;
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/build_config.dart';
import 'package:pili_aurora/common/widgets/scale_app.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/services/account_service.dart';
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
import 'package:pili_aurora/utils/utils.dart';
import 'package:catcher_2/catcher_2.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';

/// 初始化本地资源和平台服务，配置异常捕获后挂载应用根 Widget。
Future<void> bootstrapApplication([List<String> arguments = const []]) async {
  try {
    await _bootstrapApplication(arguments);
  } catch (error, stackTrace) {
    logger.e('应用启动失败', error: error, stackTrace: stackTrace);
    await Diagnostics.instance.flush();
    rethrow;
  }
}

Future<void> _bootstrapApplication(List<String> arguments) async {
  initializePresentationEngineConfiguration();
  ScaledWidgetsFlutterBinding.ensureInitialized();
  await initializeSupportPath();
  final windows = DesktopPlaybackWindows.instance;
  final playerWindow =
      Platform.isWindows &&
      arguments.firstOrNull == DesktopPlaybackWindows.argument;
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
  final initialization = playerWindow ? await windows.connectPlayer() : null;
  if (playerWindow) {
    Diagnostics.instance.forwardRecord = windows.sendDiagnosticRecord;
    Diagnostics.instance.forwardFlush = windows.flushDiagnostics;
  }
  MediaKit.ensureInitialized();
  try {
    await GStorage.init(memorySnapshot: initialization?.storage);
  } catch (e, stack) {
    logger.e('GStorage init error', error: e, stackTrace: stack);
    await Diagnostics.instance.flush();
    if (playerWindow) {
      windows.playerFailed();
      exit(1);
    }
    await Utils.copyText(e.toString(), needToast: false);
    exit(0);
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
  await LoggerUtils.initialize();
  if (playerWindow) await windows.applyDiagnosticSettings();
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
  if (!playerWindow) await initializePlatformServices();

  Request();
  Request.setCookie(syncWebView: !playerWindow);
  if (!playerWindow) RequestUtils.syncHistoryStatus();
  windows.setLocalMuted = (muted) async {
    await PlPlayerController.instance?.setMuted(muted);
  };

  SmartDialog.config.toast = SmartConfigToast(displayType: .onlyRefresh);

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
