import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:pili_aurora/services/desktop_playback_layout.dart';
import 'package:pili_aurora/services/desktop_playback_request.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

class _PlaybackWindow {
  _PlaybackWindow(
    this.id,
    this.token,
    this.initialization,
    this.cacheDirectory,
  );
  final int id;
  final String token;
  final Map<String, dynamic> initialization;
  final Directory cacheDirectory;
  final ready = Completer<void>();
  WebSocket? socket;
  Process? process;
}

/// 每个播放进程拥有独立播放器；主进程负责排列、声音切换和保存几何信息。
/// IPC 绑定回环地址，使用一次性随机凭证；登录快照不进入命令行或磁盘文件。
class DesktopPlaybackWindows with WindowListener {
  DesktopPlaybackWindows._();
  static final instance = DesktopPlaybackWindows._();
  static const argument = '--piliaurora-player-window';
  static const _boundsKey = 'desktopPlaybackWindowBounds';
  static bool get isPlayerWindow => instance._childSocket != null;
  bool get canArrange =>
      !isPlayerWindow || _childSocket?.readyState == WebSocket.open;

  final _windows = <int, _PlaybackWindow>{};
  Future<HttpServer>? _server;
  WebSocket? _childSocket;
  StreamSubscription? _childSubscription;
  Timer? _boundsTimer;
  Future<void> Function(bool)? setLocalMuted;
  Future<void> Function()? onPlayerClose;
  Rect? initialBounds;
  double? initialVolume;
  Directory? cacheDirectory;
  bool _closing = false;

  Future<HttpServer> _ensureServer() => _server ??= () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final token = request.headers.value(HttpHeaders.authorizationHeader);
      final matches = _windows.values.where(
        (window) => window.token == token && window.socket == null,
      );
      if (!WebSocketTransformer.isUpgradeRequest(request) || matches.isEmpty) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      final window = matches.first;
      try {
        final socket = window.socket = await WebSocketTransformer.upgrade(
          request,
        );
        final payload = jsonEncode(window.initialization);
        window.initialization.clear();
        socket
          ..add(payload)
          ..listen(
            (data) => _onWindowMessage(window, jsonDecode(data as String)),
            onDone: () {
              if (!window.ready.isCompleted) {
                window.ready.completeError(StateError('播放窗口启动中断'));
              }
              window.socket = null;
            },
            onError: (Object error) {
              if (!window.ready.isCompleted) {
                window.ready.completeError(StateError('播放窗口连接失败'));
              }
            },
          );
      } catch (_) {
        if (!window.ready.isCompleted) {
          window.ready.completeError(StateError('播放窗口连接失败'));
        }
      }
    });
    return server;
  }();

  void _onWindowMessage(_PlaybackWindow window, Map<String, dynamic> message) {
    switch (message['type']) {
      case 'ready':
        if (!window.ready.isCompleted) window.ready.complete();
      case 'bounds':
        final bounds = (message['bounds'] as List).cast<num>();
        if (bounds.length == 4 &&
            bounds.every((v) => v.isFinite) &&
            bounds[2] > 0 &&
            bounds[3] > 0) {
          final saved = Map<dynamic, dynamic>.from(
            GStorage.setting.get(
              _boundsKey,
              defaultValue: <dynamic, dynamic>{},
            ),
          );
          saved[window.id.toString()] = bounds;
          GStorage.setting.put(_boundsKey, saved);
        }
      case 'arrange':
        unawaited(
          arrange(DesktopPlaybackLayout.values.byName(message['layout'])),
        );
      case 'solo':
        unawaited(_solo(window.id));
      case 'progress':
        final cid = message['cid'] as int;
        final position = message['position'] as int;
        if (cid > 0 && position >= 0) {
          GStorage.watchProgress.put(cid.toString(), position);
        }
      case 'failed':
        if (!window.ready.isCompleted) {
          window.ready.completeError(StateError('播放窗口初始化失败'));
        }
    }
  }

  Future<void> open(DesktopPlaybackRequest request, {double? volume}) async {
    if (isPlayerWindow) throw StateError('请从主窗口打开新的播放窗口');
    final server = await _ensureServer();
    final snapshot = await GStorage.playbackSnapshot();
    var id = 0;
    while (_windows.containsKey(id)) {
      id++;
    }
    final saved = GStorage.setting.get(_boundsKey) as Map?;
    final cached = saved?[id.toString()] as List?;
    final previousBounds = cached == null
        ? null
        : Rect.fromLTWH(
            cached[0].toDouble(),
            cached[1].toDouble(),
            cached[2].toDouble(),
            cached[3].toDouble(),
          );
    final workArea = await _workArea(restoreBounds: previousBounds);
    final bounds = DesktopPlaybackGeometry.fit(
      previousBounds ??
          Rect.fromLTWH(
            workArea.left + 64 + id * 24,
            workArea.top + 64 + id * 24,
            640,
            400,
          ),
      workArea,
    );
    final directory = await Directory.systemTemp.createTemp(
      'piliaurora-player-',
    );
    final token = base64UrlEncode(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    );
    final window = _PlaybackWindow(id, token, {
      'request': request.toJson(),
      'volume': volume,
      'storage': snapshot.map(
        (key, value) => MapEntry(key, base64Encode(value)),
      ),
      'bounds': _rectValues(bounds),
      'cacheDirectory': directory.path,
    }, directory);
    _windows[id] = window;
    try {
      window.process = await Process.start(
        Platform.resolvedExecutable,
        [argument],
        workingDirectory: File(Platform.resolvedExecutable).parent.path,
        environment: {
          'PILIAURORA_WINDOW_PORT': '${server.port}',
          'PILIAURORA_WINDOW_TOKEN': token,
        },
      );
      // 子窗口日志由其诊断模块处理，管道持续消费以免阻塞进程。
      unawaited(window.process!.stdout.drain<void>());
      unawaited(window.process!.stderr.drain<void>());
      unawaited(
        window.process!.exitCode.then((_) async {
          if (identical(_windows[id], window)) {
            _windows.remove(id);
          }
          if (!window.ready.isCompleted) {
            window.ready.completeError(StateError('播放窗口启动失败'));
          }
          await window.socket?.close();
          if (directory.existsSync()) await directory.delete(recursive: true);
        }),
      );
      await window.ready.future.timeout(const Duration(seconds: 45));
      await _solo(id);
    } catch (_) {
      if (identical(_windows[id], window)) {
        _windows.remove(id);
      }
      window.process?.kill();
      await window.socket?.close();
      if (window.process == null && directory.existsSync()) {
        await directory.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<({DesktopPlaybackRequest request, Map<String, Uint8List> storage})>
  connectPlayer() async {
    final port = int.parse(Platform.environment['PILIAURORA_WINDOW_PORT']!);
    final token = Platform.environment['PILIAURORA_WINDOW_TOKEN']!;
    final socket = _childSocket = await WebSocket.connect(
      'ws://127.0.0.1:$port',
      headers: {HttpHeaders.authorizationHeader: token},
    );
    final initialization = Completer<Map<String, dynamic>>();
    _childSubscription = socket.listen(
      (data) {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        if (!initialization.isCompleted) {
          initialization.complete(message);
        } else {
          switch (message['type']) {
            case 'bounds':
              final values = (message['bounds'] as List).cast<num>();
              unawaited(
                windowManager.setBounds(
                  Rect.fromLTWH(
                    values[0].toDouble(),
                    values[1].toDouble(),
                    values[2].toDouble(),
                    values[3].toDouble(),
                  ),
                ),
              );
            case 'mute':
              unawaited(setLocalMuted?.call(message['muted'] as bool));
          }
        }
      },
      onDone: () {
        if (!initialization.isCompleted) {
          initialization.completeError(StateError('主窗口连接已关闭'));
        }
      },
      onError: (Object error) {
        if (!initialization.isCompleted) {
          initialization.completeError(StateError('主窗口连接失败'));
        }
      },
    );
    final data = await initialization.future.timeout(
      const Duration(seconds: 15),
    );
    final bounds = (data['bounds'] as List).cast<num>();
    initialBounds = Rect.fromLTWH(
      bounds[0].toDouble(),
      bounds[1].toDouble(),
      bounds[2].toDouble(),
      bounds[3].toDouble(),
    );
    cacheDirectory = Directory(data['cacheDirectory'] as String);
    initialVolume = (data['volume'] as num?)?.toDouble();
    return (
      request: DesktopPlaybackRequest.fromJson(
        Map<String, dynamic>.from(data['request'] as Map),
      ),
      storage: (data['storage'] as Map).map(
        (key, value) => MapEntry(key as String, base64Decode(value as String)),
      ),
    );
  }

  Future<void> watchPlayerWindow() async {
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
  }

  void _sendChild(Map<String, dynamic> message) {
    if (_childSocket?.readyState == WebSocket.open) {
      _childSocket!.add(jsonEncode(message));
    }
  }

  void playerReady() => _sendChild({'type': 'ready'});
  void playerFailed() => _sendChild({'type': 'failed'});
  void savePlaybackProgress(int cid, int position) =>
      _sendChild({'type': 'progress', 'cid': cid, 'position': position});

  Future<void> arrange(DesktopPlaybackLayout layout) async {
    if (isPlayerWindow) {
      _sendChild({'type': 'arrange', 'layout': layout.name});
      return;
    }
    final windows = _windows.values
        .where((window) => window.socket != null)
        .toList();
    final bounds = DesktopPlaybackGeometry.arrange(
      windows.length,
      await _workArea(),
      layout,
    );
    for (var i = 0; i < windows.length; i++) {
      windows[i].socket?.add(
        jsonEncode({'type': 'bounds', 'bounds': _rectValues(bounds[i])}),
      );
    }
  }

  Future<void> solo() async {
    if (isPlayerWindow) {
      if (_childSocket?.readyState == WebSocket.open) {
        _sendChild({'type': 'solo'});
      } else {
        await setLocalMuted?.call(false);
      }
    } else {
      await _solo(null);
    }
  }

  Future<void> _solo(int? id) async {
    await setLocalMuted?.call(id != null);
    for (final window in _windows.values) {
      window.socket?.add(
        jsonEncode({'type': 'mute', 'muted': window.id != id}),
      );
    }
  }

  static List<double> _rectValues(Rect rect) => [
    rect.left,
    rect.top,
    rect.width,
    rect.height,
  ];

  static Future<Rect> _workArea({Rect? restoreBounds}) async {
    final cursor = await screenRetriever.getCursorScreenPoint();
    final displays = await screenRetriever.getAllDisplays();
    final display = displays.firstWhere(
      (display) => ((display.visiblePosition ?? Offset.zero) & display.size)
          .contains(restoreBounds?.center ?? cursor),
      orElse: () => displays.firstWhere(
        (display) => ((display.visiblePosition ?? Offset.zero) & display.size)
            .contains(cursor),
        orElse: () => displays.first,
      ),
    );
    return (display.visiblePosition ?? Offset.zero) &
        (display.visibleSize ?? display.size);
  }

  void _saveBounds() {
    _boundsTimer?.cancel();
    _boundsTimer = Timer(const Duration(milliseconds: 250), () async {
      if (await windowManager.isMinimized() ||
          await windowManager.isFullScreen()) {
        return;
      }
      final bounds = await windowManager.getBounds();
      if (_childSocket?.readyState == WebSocket.open) {
        _childSocket!.add(
          jsonEncode({'type': 'bounds', 'bounds': _rectValues(bounds)}),
        );
      }
    });
  }

  @override
  void onWindowMoved() => _saveBounds();
  @override
  void onWindowResized() => _saveBounds();
  @override
  Future<void> onWindowClose() async {
    if (_closing) return;
    _closing = true;
    _boundsTimer?.cancel();
    final bounds =
        await windowManager.isMinimized() || await windowManager.isFullScreen()
        ? null
        : await windowManager.getBounds();
    await onPlayerClose?.call();
    if (_childSocket?.readyState == WebSocket.open) {
      if (bounds != null) {
        _childSocket!.add(
          jsonEncode({'type': 'bounds', 'bounds': _rectValues(bounds)}),
        );
      }
      await _childSocket!.close();
    }
    await _childSubscription?.cancel();
    windowManager.removeListener(this);
    await windowManager.destroy();
  }
}
