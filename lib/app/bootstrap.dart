import 'dart:io';

import 'package:pili_aurora/app/app.dart';
import 'package:pili_aurora/app/app_paths.dart';
import 'package:pili_aurora/app/platform_setup.dart';
import 'package:pili_aurora/services/desktop_playback_windows.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
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
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/request_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/theme_utils.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:catcher_2/catcher_2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';

/// 初始化本地资源和平台服务，配置异常捕获后挂载应用根 Widget。
Future<void> bootstrapApplication([List<String> arguments = const []]) async {
  ScaledWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await initializeSupportPath();
  final windows = DesktopPlaybackWindows.instance;
  final playerWindow =
      Platform.isWindows &&
      arguments.firstOrNull == DesktopPlaybackWindows.argument;
  final initialization = playerWindow ? await windows.connectPlayer() : null;
  try {
    await GStorage.init(memorySnapshot: initialization?.storage);
  } catch (e) {
    if (playerWindow) {
      windows.playerFailed();
      exit(1);
    }
    await Utils.copyText(e.toString(), needToast: false);
    logger.e('GStorage init error', error: e);
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
    });
  }
  ScaledWidgetsFlutterBinding.instance.scaleFactor = Pref.uiScale;
  if (!playerWindow) await LoggerUtils.initialize();
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
            '忽略损坏的下载记录: $path',
            error: error,
            stackTrace: stackTrace,
          ),
        ),
        downloadClient: Request.http11Dio,
      ),
    );
  HttpOverrides.global = _CustomHttpOverrides();

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
      await controller?.pause();
      controller?.dispose();
      await CacheManager.manager.dispose();
      await GStorage.close();
      final directory = windows.cacheDirectory!;
      if (directory.existsSync()) await directory.delete(recursive: true);
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
    if (kDebugMode || Pref.badCertificateCallback) {
      client.badCertificateCallback = (cert, host, port) => true;
    }
    return client;
  }
}
