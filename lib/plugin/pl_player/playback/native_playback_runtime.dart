import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/http/browser_ua.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/services/android_video_output_limit.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/player_diagnostics.dart';
import 'package:pili_aurora/services/windows_video_output_limit.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/utils/hardware_video_configuration.dart';
import 'package:pili_aurora/plugin/pl_player/utils/native_media_source.dart';

/// 原生资源只在首次加载时创建，切源复用 Player、VideoController 和纹理输出。
class NativePlaybackRuntime {
  NativePlaybackRuntime({required this.diagnosticsExtra});

  final Map<String, Object?> Function() diagnosticsExtra;
  Player? _player;
  VideoController? _videoController;
  PlayerDiagnostics? _diagnostics;
  bool _disposed = false;

  Player? get player => _player;
  VideoController? get videoController => _videoController;
  PlayerDiagnostics? get diagnostics => _diagnostics;

  /// 由会话加载队列调用；尚未发布的资源在初始化失败或关闭时就地释放。
  Future<Player?> initialize({
    required double volume,
    int? width,
    int? height,
  }) async {
    if (_disposed) return null;
    if (_player != null) return _player;
    final options = {
      'video-sync': Pref.videoSync,
      if (Platform.isAndroid) 'ao': Pref.audioOutput,
      'volume': (PlatformUtils.isMobile ? Pref.playerVolume : volume * 100)
          .toString(),
      if (Pref.autosync != '0') 'autosync': Pref.autosync,
    };
    final player = await Player.create(
      configuration: PlayerConfiguration(
        logLevel: kDebugMode ? .warn : .error,
        options: options,
      ),
    );
    if (_disposed) {
      await player.dispose();
      return null;
    }
    final diagnostics = PlayerDiagnostics(player, extra: diagnosticsExtra);
    final VideoController video;
    try {
      video = await VideoController.create(
        player,
        configuration: hardwareVideoConfiguration(
          enabled: Pref.enableHA,
          configured: Pref.hardwareDecoding,
          windowsSourceSize:
              Platform.isWindows && width != null && height != null
              ? (width: width, height: height)
              : null,
          windowsOutputLimit: Platform.isWindows
              ? WindowsVideoOutputLimit.detected
              : null,
          androidOutputLimit: Platform.isAndroid
              ? () => Pref.enableAndroidTextureScaling
                    ? AndroidVideoOutputLimit.detected
                    : null
              : null,
          onAndroidDiagnostic: (action, details) => diagnostics.event(
            action,
            level: action.contains('error')
                ? DiagnosticLogLevel.error
                : DiagnosticLogLevel.info,
            details: details,
          ),
        ),
      );
      if (Platform.isAndroid) player.setProperty('force-window', 'no');
      player.setMediaHeader(
        userAgent: BrowserUa.pc,
        referer: HttpString.baseUrl,
      );
    } catch (error) {
      diagnostics
        ..event(
          'player.create.failed',
          level: DiagnosticLogLevel.error,
          details: {'error': error},
        )
        ..dispose();
      await player.dispose();
      rethrow;
    }
    if (_disposed) {
      diagnostics.dispose();
      await player.dispose();
      return null;
    }
    _player = player;
    _videoController = video;
    _diagnostics = diagnostics;
    return player;
  }

  Future<bool> open({
    required DataSource source,
    required bool audioOnly,
    required bool Function() isCurrent,
    Duration? start,
    Map<String, String> extras = const {},
  }) async {
    final player = _player;
    if (_disposed || player == null || !isCurrent()) return false;
    player.setProperty(
      'hwdec',
      hardwareVideoConfiguration(
        enabled: Pref.enableHA,
        configured: Pref.hardwareDecoding,
      ).hwdec!,
    );
    _diagnostics?.event(
      'media.open.requested',
      details: {
        'startMs': start?.inMilliseconds,
        'sourceType': source.runtimeType.toString(),
        'audioOnly': audioOnly,
      },
    );
    final watch = Stopwatch()..start();
    await player.open(
      nativeMediaSource(
        source: source,
        audioOnly: audioOnly,
        start: start,
        extras: extras,
      ),
      play: false,
    );
    _diagnostics?.event(
      'media.open.completed',
      details: {
        'durationUs': watch.elapsedMicroseconds,
        'isCurrent': isCurrent(),
      },
    );
    return !_disposed && isCurrent();
  }

  /// 先使资源不可见，再等已发出的原生操作结束，避免 open 与 dispose 交错。
  Future<void> dispose({required Future<void> after}) async {
    if (_disposed) return;
    _disposed = true;
    final player = _player;
    _player = null;
    _videoController = null;
    _diagnostics?.dispose();
    _diagnostics = null;
    await after;
    await player?.dispose();
  }
}
