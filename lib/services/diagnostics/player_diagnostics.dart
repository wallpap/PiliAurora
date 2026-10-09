import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

/// 分离 mpv 原始日志、播放器状态和解码上下文；低等级只记录边界，不逐帧刷屏。
class PlayerDiagnostics {
  PlayerDiagnostics(this.player, {this.extra}) {
    for (final name in _propertyNames) {
      _subscriptions.add(
        player
            .observeProperty(name)
            .listen(
              (value) => _properties[name] = value,
              onError: (Object error) {
                _properties[name] = null;
              },
            ),
      );
    }
    _unregister = Diagnostics.instance.register(playerId, snapshot);
    player.onLoadHooks.add(_onLoad);
    player.onUnloadHooks.add(_onUnload);
    _subscriptions.addAll([
      player.stream.log.listen(_onLog),
      player.stream.playing.distinct().listen(
        (value) => event('playback.playing', details: {'value': value}),
      ),
      player.stream.buffering.distinct().listen(
        (value) => event('playback.buffering', details: {'value': value}),
      ),
      player.stream.completed.distinct().listen(
        (value) => event('playback.completed', details: {'value': value}),
      ),
      player.stream.videoParams.distinct().listen(
        (value) => event(
          'video.parameters',
          details: {
            'dw': value.dw,
            'dh': value.dh,
            'rotate': value.rotate,
          },
        ),
      ),
      player.stream.error.listen(
        (value) => event(
          'playback.error',
          level: DiagnosticLogLevel.error,
          details: {'error': value, 'mpvContext': _context.toList()},
        ),
      ),
    ]);
    Diagnostics.instance.addListener(_updateLevel);
    _updateLevel();
    event(
      'player.created',
      details: {
        'platform': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
      },
    );
  }

  final NativePlayer player;
  final Map<String, Object?> Function()? extra;
  final _properties = <String, String?>{};
  late final void Function() _unregister;
  final _subscriptions = <StreamSubscription>[];
  final _context = Queue<Map<String, Object?>>();
  DiagnosticLogLevel? _level;
  Timer? _timer;
  int _mediaGeneration = 0;
  bool _disposed = false;
  Map<String, Object?>? _lastDecoder;
  final _errorClock = Stopwatch()..start();
  final _lastErrorContext = <String, int>{};

  String get playerId => 'player.${player.hashCode}';
  String? property(String name) => _disposed ? null : _properties[name];
  String? _property(String name) => property(name);

  static final _propertyNames = [
    'mpv-version',
    'ffmpeg-version',
    'hwdec',
    'hwdec-current',
    'video-codec',
    'video-format',
    'video-dec-params',
    'video-params',
    'video-out-params',
    'vo',
    'current-vo',
    'gpu-api',
    'gpu-context',
    'estimated-vf-fps',
    'decoder-frame-drop-count',
    'frame-drop-count',
    'mistimed-frame-count',
    'vo-delayed-frame-count',
    'avsync',
    'demuxer-cache-state',
    'paused-for-cache',
    'eof-reached',
    'seeking',
    'video-pts',
    if (Platform.isAndroid) ...[
      'android-surface-size',
      'osd-dimensions',
      'wid',
    ],
  ];

  Map<String, Object?> snapshot() => {
    ..._properties,
    'playerId': playerId,
    'handle': player.disposed ? null : player.handle,
    'mediaGeneration': _mediaGeneration,
    'playing': player.state.playing,
    'buffering': player.state.buffering,
    'completed': player.state.completed,
    'positionMs': player.state.position.inMilliseconds,
    'bufferMs': player.state.buffer.inMilliseconds,
    'width': player.state.width,
    'height': player.state.height,
    'speed': player.state.rate,
    'viewports': Diagnostics.instance.readSources(
      prefix: 'videoViewport.${player.hashCode}.',
    ),
    ...?extra?.call(),
  };

  void event(
    String action, {
    DiagnosticLogLevel level = DiagnosticLogLevel.info,
    Map<String, Object?>? details,
  }) {
    if (_disposed || !Diagnostics.instance.acceptsPlayer(level)) return;
    try {
      Diagnostics.instance.playerLog(
        level,
        'player',
        action,
        details: {...snapshot(), ...?details},
      );
    } catch (_) {
      // 诊断读取失败不参与加载与解码控制。
    }
  }

  Future<void> _onLoad() async {
    _mediaGeneration++;
    for (final name in [
      'hwdec-current',
      'video-pts',
      'eof-reached',
      'seeking',
    ]) {
      _properties.remove(name);
    }
    _context.clear();
    _lastErrorContext.clear();
    _lastDecoder = null;
    event('media.load');
  }

  Future<void> _onUnload() async => event('media.unload');

  void _onLog(PlayerLog log) {
    final level = switch (log.level) {
      'fatal' || 'error' => DiagnosticLogLevel.error,
      'warn' => DiagnosticLogLevel.warning,
      'info' || 'status' => DiagnosticLogLevel.info,
      'debug' || 'v' => DiagnosticLogLevel.debug,
      _ => DiagnosticLogLevel.trace,
    };
    if (_disposed) return;
    final details = {
      'playerId': playerId,
      'mediaGeneration': _mediaGeneration,
      'prefix': log.prefix,
      'nativeLevel': log.level,
    };
    if (Diagnostics.instance.playerLevel != DiagnosticLogLevel.off) {
      _context.add({...details, 'message': log.text});
      while (_context.length > 24) {
        _context.removeFirst();
      }
    }
    Diagnostics.instance.playerLog(level, 'mpv', log.text, details: details);
    // 原始错误只写一次；上下文快照仅在错误边界采集，不对每条 mpv 文本读取所有属性。
    if (level == DiagnosticLogLevel.error &&
        Diagnostics.instance.acceptsPlayer(level)) {
      final now = _errorClock.elapsedMilliseconds;
      final previous = _lastErrorContext[log.prefix];
      if (previous == null || now - previous >= 1000) {
        _lastErrorContext[log.prefix] = now;
        event(
          'mpv.error.context',
          level: level,
          details: {
            'prefix': log.prefix,
            'trigger': log.text,
            'note': '同前缀错误快照限频 1 秒；全部原始错误保留在 mpv 记录中',
          },
        );
      }
    }
  }

  void _sample() {
    if (_disposed || player.disposed || player.current.isEmpty) return;
    final state = {
      for (final name in [
        'hwdec',
        'hwdec-current',
        'video-codec',
        'current-vo',
      ])
        name: _property(name),
    };
    if (_lastDecoder == null ||
        state.entries.any((e) => _lastDecoder![e.key] != e.value)) {
      event(
        'decoder.state.changed',
        details: {'previous': _lastDecoder, 'current': state},
      );
      _lastDecoder = state;
    }
    event(
      'playback.snapshot',
      level: Diagnostics.instance.playerLevel == DiagnosticLogLevel.trace
          ? DiagnosticLogLevel.trace
          : DiagnosticLogLevel.debug,
    );
  }

  void _updateLevel() {
    final level = Diagnostics.instance.playerLevel;
    if (_disposed || player.disposed || level == _level) return;
    _level = level;
    _timer?.cancel();
    _timer = null;
    if (level != DiagnosticLogLevel.off &&
        level.index <= DiagnosticLogLevel.info.index) {
      _timer = Timer.periodic(
        Duration(milliseconds: level == DiagnosticLogLevel.trace ? 250 : 2000),
        (_) => _sample(),
      );
    }
    // 关闭保存仍请求 error：不能破坏 media_kit 的错误事件和已有恢复逻辑。
    final name = switch (level) {
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
    event(
      'logging.configured',
      details: {'playerLogLevel': level.name, 'nativeLogLevel': name},
    );
  }

  void dispose() {
    if (_disposed) return;
    event('player.disposed');
    _disposed = true;
    _timer?.cancel();
    player.onLoadHooks.remove(_onLoad);
    player.onUnloadHooks.remove(_onUnload);
    _unregister();
    Diagnostics.instance.removeListener(_updateLevel);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _context.clear();
  }
}

/// 同步读取 mpv 属性；不可用时保留 null，并在成功和失败路径释放原生内存。
///
/// 只在播放器所属 isolate、仍存活时调用；采样方必须把同步耗时计入扰动预算。
String? readMpvProperty(NativePlayer player, String name) {
  if (player.disposed) return null;
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
