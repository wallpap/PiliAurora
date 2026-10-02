import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

/// 跟随播放器生命周期注册指标和日志；取消注册后不再访问原生句柄。
class PlayerDiagnostics {
  PlayerDiagnostics(this.player, {Map<String, Object?> Function()? extra}) {
    // 原生版本在播放器生命周期内固定，无须每个采样窗口重新查询。
    final versions = {
      'mpv-version': _property('mpv-version'),
      'ffmpeg-version': _property('ffmpeg-version'),
    };
    _unregister = Diagnostics.instance.register(
      'player.${player.hashCode}',
      () => {
        ...versions,
        'playing': player.state.playing,
        'buffering': player.state.buffering,
        'positionMs': player.state.position.inMilliseconds,
        'bufferMs': player.state.buffer.inMilliseconds,
        'width': player.state.width,
        'height': player.state.height,
        'speed': player.state.rate,
        for (final property in [
          'hwdec-current',
          'video-codec',
          'video-format',
          'estimated-vf-fps',
          'decoder-frame-drop-count',
          'frame-drop-count',
        ])
          property: _property(property),
        ...?extra?.call(),
      },
    );
    _subscription = player.stream.log.listen((event) {
      final level = switch (event.level) {
        'fatal' || 'error' => DiagnosticLogLevel.error,
        'warn' => DiagnosticLogLevel.warning,
        'info' || 'status' => DiagnosticLogLevel.info,
        'debug' || 'v' => DiagnosticLogLevel.debug,
        _ => DiagnosticLogLevel.trace,
      };
      Diagnostics.instance.log(
        level,
        'mpv',
        event.text,
        details: {'prefix': event.prefix},
      );
    });
    Diagnostics.instance.addListener(_updateLevel);
    _updateLevel();
  }

  final NativePlayer player;
  late final void Function() _unregister;
  late final StreamSubscription<PlayerLog> _subscription;
  DiagnosticLogLevel? _level;
  bool _disposed = false;

  String? _property(String name) {
    if (_disposed || player.disposed) return null;
    final property = name.toNativeUtf8();
    try {
      final value = NativePlayer.mpv.mpv_get_property_string(
        player.ctx,
        property.cast(),
      );
      try {
        return value == nullptr ? null : value.cast<Utf8>().toDartString();
      } finally {
        if (value != nullptr) NativePlayer.mpv.mpv_free(value.cast());
      }
    } catch (_) {
      return null;
    } finally {
      // 当前 media_kit 的 getProperty 在属性不存在时会漏释放名称。
      calloc.free(property);
    }
  }

  void _updateLevel() {
    final level = Diagnostics.instance.level;
    if (_disposed || player.disposed || level == _level) return;
    _level = level;
    final name = switch (level) {
      // media_kit 还用原生 error 消息生成播放错误和解码回退事件。
      // 关闭日志仅停止保存，不能关闭这些功能事件。
      DiagnosticLogLevel.off => 'error',
      DiagnosticLogLevel.warning => 'warn',
      _ => level.name,
    };
    final value = name.toNativeUtf8();
    try {
      NativePlayer.mpv.mpv_request_log_messages(player.ctx, value.cast());
    } finally {
      calloc.free(value);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _unregister();
    Diagnostics.instance.removeListener(_updateLevel);
    unawaited(_subscription.cancel());
  }
}
