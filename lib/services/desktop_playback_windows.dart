import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/window_coordinator.dart';
import 'package:pili_aurora/services/desktop_playback_layout.dart';
import 'package:pili_aurora/services/desktop_playback_request.dart';
import 'package:pili_aurora/services/windows_update_exit.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

class _PlaybackWindow {
  _PlaybackWindow(
    this.id,
    this.token,
    this.initialization,
    this.cacheDirectory,
  ) {
    // IPC 或进程退出可能早于 Process.start 返回；随后仍由 open 等待同一结果。
    ready.future.ignore();
  }
  final int id;
  final String token;
  final Map<String, dynamic> initialization;
  final Directory cacheDirectory;
  final ready = Completer<void>();
  WebSocket? socket;
  Process? process;
  Future<Process>? startingProcess;
  Future<void>? exitCleanup;
  bool connectionClaimed = false;
}

typedef DesktopPlaybackProcessStarter = Future<Process> Function(
  Map<String, String> environment,
);

typedef DesktopPlaybackInitialization = ({
  DesktopPlaybackRequest request,
  Map<String, Uint8List> storage,
});

Future<Process> _startPlayerProcess(Map<String, String> environment) =>
    Process.start(
      Platform.resolvedExecutable,
      [DesktopPlaybackWindows.argument],
      workingDirectory: File(Platform.resolvedExecutable).parent.path,
      environment: environment,
    );

/// 每个播放进程拥有独立播放器；主进程负责排列、声音切换和保存几何信息。
/// IPC 绑定回环地址，使用一次性随机凭证；登录快照不进入命令行或磁盘文件。
class DesktopPlaybackWindows with WindowListener {
  DesktopPlaybackWindows({
    DesktopPlaybackProcessStarter? startProcess,
    Map<String, String>? environment,
    this.startupTimeout = const Duration(seconds: 45),
    this.connectionTimeout = const Duration(seconds: 15),
  }) : _startProcess = startProcess ?? _startPlayerProcess,
       _environment = environment ?? Platform.environment;

  static final instance = DesktopPlaybackWindows();
  static const argument = '--piliaurora-player-window';
  static const _boundsKey = 'desktopPlaybackWindowBounds';
  static bool get isPlayerWindow => instance._childSocket != null;
  final DesktopPlaybackProcessStarter _startProcess;
  final Map<String, String> _environment;
  final Duration startupTimeout;
  final Duration connectionTimeout;
  bool get canArrange =>
      _childSocket == null || _childSocket?.readyState == WebSocket.open;

  final _windows = <int, _PlaybackWindow>{};
  final _openingIds = <int>{};
  final _processCleanups = <Future<void>>{};
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
  Future<void>? _shutdown;
  Future<void>? _showPlayerWindow;
  Future<void> _soundChange = Future<void>.value();
  int _soundVersion = 0;
  _PlaybackWindow? _soundWindow;
  Future<DesktopPlaybackInitialization>? _playerInitialization;
  Map<String, dynamic>? _diagnosticSettings;
  int _flushSequence = 0;
  late final _diagnosticCoordinator = DiagnosticWindowCoordinator(
    sockets: () => {
      for (final window in _windows.values) window.id: window.socket,
    },
    onSkipped: (ids) {
      Diagnostics.instance.skippedChildWindows
        ..clear()
        ..addAll(ids);
    },
  );
  Completer<void>? _diagnosticsResumed;
  final _flushRequests = <int, Completer<void>>{};

  void _reportFailure(String phase, Object error, StackTrace stackTrace) {
    Diagnostics.instance.log(
      DiagnosticLogLevel.warning,
      'window',
      '播放窗口操作失败: $phase',
      details: {
        'type': error.runtimeType.toString(),
        if (error is ProcessException) 'exitCode': error.errorCode,
      },
      stack: stackTrace,
    );
  }

  Future<void> _release(String phase, Future<void> Function() action) async {
    try {
      await action();
    } catch (error, stackTrace) {
      _reportFailure(phase, error, stackTrace);
    }
  }

  static Map<String, dynamic> _decodeMessage(Object? data) {
    if (data is! String) throw const FormatException('播放窗口消息必须是文本');
    final decoded = jsonDecode(data);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('播放窗口消息格式无效');
    }
    return decoded;
  }

  Future<HttpServer> _ensureServer() async {
    final pending = _server ??= _bindServer();
    try {
      return await pending;
    } catch (_) {
      if (identical(_server, pending)) _server = null;
      rethrow;
    }
  }

  Future<HttpServer> _bindServer() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(
      (request) => unawaited(_acceptWindowConnection(request)),
      onError: (Object error, StackTrace stackTrace) {
        _reportFailure('server', error, stackTrace);
      },
    );
    return server;
  }

  Future<void> _acceptWindowConnection(HttpRequest request) async {
    _PlaybackWindow? window;
    try {
      await _diagnosticsResumed?.future;
      final token = request.headers.value(HttpHeaders.authorizationHeader);
      final matches = _windows.values.where(
        (window) => window.token == token && !window.connectionClaimed,
      );
      if (!WebSocketTransformer.isUpgradeRequest(request) || matches.isEmpty) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      window = matches.first..connectionClaimed = true;
      final connectedWindow = window;
      final socket = window.socket = await WebSocketTransformer.upgrade(
        request,
      );
      final payload = jsonEncode(window.initialization);
      window.initialization.clear();
      socket
        ..add(payload)
        ..listen(
          (data) => unawaited(_onWindowData(connectedWindow, data)),
          onDone: () {
            if (!connectedWindow.ready.isCompleted) {
              connectedWindow.ready.completeError(StateError('播放窗口启动中断'));
            }
            connectedWindow.socket = null;
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!connectedWindow.ready.isCompleted) {
              connectedWindow.ready.completeError(error, stackTrace);
            }
            _reportFailure('connection', error, stackTrace);
          },
        );
    } catch (error, stackTrace) {
      if (window != null && !window.ready.isCompleted) {
        window.ready.completeError(error, stackTrace);
      }
      _reportFailure('handshake', error, stackTrace);
    }
  }

  Future<void> _onWindowData(_PlaybackWindow window, Object? data) async {
    try {
      await _onWindowMessage(window, _decodeMessage(data));
    } catch (error, stackTrace) {
      if (!window.ready.isCompleted) {
        window.ready.completeError(error, stackTrace);
      }
      _reportFailure('message', error, stackTrace);
    }
  }

  Future<void> _onWindowMessage(
    _PlaybackWindow window,
    Map<String, dynamic> message,
  ) async {
    switch (message['type']) {
      case 'diagnosticControlResult':
        _diagnosticCoordinator.receive(window.id, message);
      case 'diagnostic':
        Diagnostics.instance.receiveRecord(
          Map<String, Object?>.from(message['record'] as Map),
          windowId: window.id,
        );
      case 'diagnosticFlush':
        await Diagnostics.instance.flush();
        window.socket?.add(
          jsonEncode({'type': 'diagnosticFlushed', 'id': message['id']}),
        );
      case 'ready':
        window.socket?.add(
          jsonEncode({
            'type': 'diagnosticSettings',
            'settings': Diagnostics.instance.settings,
          }),
        );
        if (!window.ready.isCompleted) window.ready.complete();
      case 'bounds':
        final bounds = DesktopPlaybackGeometry.fromValues(message['bounds']);
        if (bounds != null) {
          final cached = GStorage.setting.get(_boundsKey);
          final saved = cached is Map
              ? Map<dynamic, dynamic>.from(cached)
              : <dynamic, dynamic>{};
          saved[window.id.toString()] = _rectValues(bounds);
          await GStorage.setting.put(_boundsKey, saved);
        }
      case 'arrange':
        await arrange(DesktopPlaybackLayout.values.byName(message['layout']));
      case 'solo':
        await _solo(window);
      case 'progress':
        final cid = message['cid'] as int;
        final position = message['position'] as int;
        if (cid > 0 && position >= 0) {
          await GStorage.watchProgress.put(cid.toString(), position);
        }
      case 'failed':
        if (!window.ready.isCompleted) {
          window.ready.completeError(StateError('播放窗口初始化失败'));
        }
      default:
        if (!window.ready.isCompleted) {
          throw const FormatException('未知播放窗口消息');
        }
    }
  }

  Future<void> open(DesktopPlaybackRequest request, {double? volume}) async {
    if (_childSocket != null) throw StateError('请从主窗口打开新的播放窗口');
    if (_shutdown != null) throw StateError('应用正在退出');
    await _diagnosticsResumed?.future;
    final server = await _ensureServer();
    final snapshot = await GStorage.playbackSnapshot();
    var id = 0;
    while (_windows.containsKey(id) || _openingIds.contains(id)) {
      id++;
    }
    _openingIds.add(id);
    try {
      await _openWindow(id, server.port, snapshot, request, volume);
    } catch (error, stackTrace) {
      _reportFailure('open', error, stackTrace);
      rethrow;
    } finally {
      _openingIds.remove(id);
    }
  }

  Future<void> _openWindow(
    int id,
    int port,
    Map<String, Uint8List> snapshot,
    DesktopPlaybackRequest request,
    double? volume,
  ) async {
    final saved = GStorage.setting.get(_boundsKey);
    final previousBounds = DesktopPlaybackGeometry.fromValues(
      saved is Map ? saved[id.toString()] : null,
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
    final token = base64UrlEncode(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    );
    final initialization = <String, dynamic>{
      'request': request.toJson(),
      'volume': volume,
      'storage': snapshot.map(
        (key, value) => MapEntry(key, base64Encode(value)),
      ),
      'bounds': _rectValues(bounds),
    };
    final directory = await Directory.systemTemp.createTemp(
      'piliaurora-player-',
    );
    initialization['cacheDirectory'] = directory.path;
    final window = _PlaybackWindow(id, token, initialization, directory);
    _windows[id] = window;
    try {
      await _diagnosticsResumed?.future;
      if (_shutdown != null) throw StateError('应用正在退出');
      final process = window.process = await (window.startingProcess =
          _startProcess({
            'PILIAURORA_WINDOW_ID': '$id',
            'PILIAURORA_WINDOW_PORT': '$port',
            'PILIAURORA_WINDOW_TOKEN': token,
          }));
      final cleanup = window.exitCleanup = _watchProcessExit(window, process);
      _processCleanups.add(cleanup);
      unawaited(
        cleanup.then((_) {
          _processCleanups.remove(cleanup);
        }),
      );
      // 子窗口日志由其诊断模块处理，管道持续消费以免阻塞进程。
      unawaited(_release('stdout', () => process.stdout.drain<void>()));
      unawaited(_release('stderr', () => process.stderr.drain<void>()));
      await window.ready.future.timeout(startupTimeout);
      await _solo(window);
    } catch (_) {
      if (identical(_windows[id], window)) {
        _windows.remove(id);
      }
      await _release('terminate', () async {
        window.process?.kill();
      });
      await _release('socket', () async {
        await window.socket?.close().timeout(const Duration(seconds: 3));
      });
      if (window.process == null) {
        await _release('cache', () async {
          if (directory.existsSync()) await directory.delete(recursive: true);
        });
      }
      rethrow;
    }
  }

  Future<void> _watchProcessExit(
    _PlaybackWindow window,
    Process process,
  ) async {
    var exited = false;
    try {
      final code = await process.exitCode;
      exited = true;
      if (!window.ready.isCompleted) {
        window.ready.completeError(
          ProcessException('PiliAurora Player', const [], '播放窗口就绪前退出', code),
          StackTrace.current,
        );
      }
    } catch (error, stackTrace) {
      if (!window.ready.isCompleted) {
        window.ready.completeError(error, stackTrace);
      }
      _reportFailure('exit', error, stackTrace);
    } finally {
      if (identical(_windows[window.id], window)) _windows.remove(window.id);
      if (exited && _shutdown == null && identical(_soundWindow, window)) {
        await _release('restoreSound', () => _solo(null));
      }
      await _release('socket', () async {
        await window.socket?.close().timeout(const Duration(seconds: 3));
      });
      await _release('cache', () async {
        if (window.cacheDirectory.existsSync()) {
          await window.cacheDirectory.delete(recursive: true);
        }
      });
    }
  }

  Future<void> closeAll() => _shutdown ??= _closeAll();

  Future<void> _closeAll() async {
    try {
      // 并行关闭，让多个小窗共用同一段退出等待时间。
      await Future.wait(
        _windows.values.toList().map((window) async {
          final Process? process;
          try {
            process = window.process ?? await window.startingProcess;
          } catch (_) {
            // 启动失败由 open 的清理流程处理。
            return;
          }
          if (process == null) return;
          if (window.socket?.readyState == WebSocket.open) {
            try {
              window.socket!.add(jsonEncode({'type': 'close'}));
              await process.exitCode.timeout(const Duration(seconds: 8));
              await window.exitCleanup;
              return;
            } on TimeoutException {
              // 原生播放器或插件释放超时后，结束该小窗进程。
            } catch (error, stackTrace) {
              _reportFailure('closeRequest', error, stackTrace);
            }
          }
          process.kill();
          await process.exitCode.timeout(const Duration(seconds: 3));
          await window.exitCleanup;
        }),
      );
      await Future.wait(_processCleanups.toList()).timeout(
        const Duration(seconds: 4),
      );
    } finally {
      await _release('server', () async {
        await (await _server)?.close(force: true);
      });
    }
  }

  Future<DesktopPlaybackInitialization> connectPlayer() =>
      _playerInitialization ??= _connectPlayer().whenComplete(
        () => _playerInitialization = null,
      );

  Future<DesktopPlaybackInitialization> _connectPlayer() async {
    if (_childSocket != null) throw StateError('播放窗口已完成连接');
    final port = int.tryParse(_environment['PILIAURORA_WINDOW_PORT'] ?? '');
    final token = _environment['PILIAURORA_WINDOW_TOKEN'];
    if (port == null ||
        port <= 0 ||
        port > 65535 ||
        token == null ||
        token.isEmpty) {
      throw ArgumentError('缺少有效的播放窗口连接参数');
    }
    final client = HttpClient()..connectionTimeout = connectionTimeout;
    final initialization = Completer<Map<String, dynamic>>();
    try {
      final connecting = WebSocket.connect(
        'ws://127.0.0.1:$port',
        headers: {HttpHeaders.authorizationHeader: token},
        customClient: client,
      );
      final socket = _childSocket = await connecting.timeout(
        connectionTimeout,
        onTimeout: () {
          client.close(force: true);
          // 处理已升级却晚于超时交付的 socket，避免脱离 HttpClient 后失去持有者。
          unawaited(
            connecting.then<void>(
              (lateSocket) => _release('lateConnection', () async {
                await lateSocket.close().timeout(const Duration(seconds: 3));
              }),
              onError: (Object _, StackTrace _) {},
            ),
          );
          throw TimeoutException('播放窗口握手超时', connectionTimeout);
        },
      );
      // 网络回调可能先于下方 await 失败，所有完成路径都必须有人接收。
      initialization.future.ignore();
      _childSubscription = socket.listen(
        (data) => unawaited(_onParentData(data, initialization)),
        onDone: () {
          if (!initialization.isCompleted) {
            initialization.completeError(StateError('主窗口连接已关闭'));
          }
          _failFlushRequests(StateError('主窗口连接已关闭'), StackTrace.current);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!initialization.isCompleted) {
            initialization.completeError(error, stackTrace);
          }
          _failFlushRequests(error, stackTrace);
          _reportFailure('parentConnection', error, stackTrace);
        },
      );
      final data = await initialization.future.timeout(connectionTimeout);
      final bounds = DesktopPlaybackGeometry.fromValues(data['bounds']);
      final directory = data['cacheDirectory'];
      final volume = data['volume'];
      if (bounds == null ||
          directory is! String ||
          directory.isEmpty ||
          (volume != null && (volume is! num || !volume.isFinite)) ||
          data['storage'] is! Map ||
          data['request'] is! Map) {
        throw const FormatException('播放窗口初始化数据无效');
      }
      final request = DesktopPlaybackRequest.fromJson(
        Map<String, dynamic>.from(data['request'] as Map),
      );
      final storage = (data['storage'] as Map).map(
        (key, value) => MapEntry(key as String, base64Decode(value as String)),
      );
      // 完整解析后才提交状态，失败连接不会留下半份初始化数据。
      initialBounds = bounds;
      cacheDirectory = Directory(directory);
      initialVolume = (volume as num?)?.toDouble();
      return (request: request, storage: storage);
    } catch (_) {
      await disconnectPlayer();
      _childSocket = null;
      rethrow;
    } finally {
      // 升级成功的 socket 已从 HttpClient 分离；超时则终止仍在等待的握手。
      client.close(force: true);
    }
  }

  Future<void> _onParentData(
    Object? data,
    Completer<Map<String, dynamic>> initialization,
  ) async {
    try {
      final message = _decodeMessage(data);
      if (!initialization.isCompleted) {
        initialization.complete(message);
      } else {
        await _onParentMessage(message);
      }
    } catch (error, stackTrace) {
      if (!initialization.isCompleted) {
        initialization.completeError(error, stackTrace);
      }
      _reportFailure('parentMessage', error, stackTrace);
    }
  }

  Future<void> _onParentMessage(Map<String, dynamic> message) async {
    switch (message['type']) {
      case 'close':
        await onWindowClose();
      case 'diagnosticControl':
        await _handleDiagnosticControl(message);
      case 'diagnosticSettings':
        await applyDiagnosticSettings(
          Map<String, dynamic>.from(message['settings'] as Map),
        );
      case 'diagnosticFlushed':
        _flushRequests.remove(message['id'])?.complete();
      case 'bounds':
        final bounds = DesktopPlaybackGeometry.fromValues(message['bounds']);
        if (bounds == null) throw const FormatException('播放窗口尺寸无效');
        await windowManager.setBounds(bounds);
      case 'mute':
        await setLocalMuted?.call(message['muted'] as bool);
    }
  }

  void _failFlushRequests(Object error, StackTrace stackTrace) {
    final requests = _flushRequests.values.toList();
    _flushRequests.clear();
    for (final request in requests) {
      if (!request.isCompleted) request.completeError(error, stackTrace);
    }
  }

  /// 仅释放 IPC；正常窗口关闭还需等待播放器与缓存释放。
  Future<void> disconnectPlayer() async {
    _failFlushRequests(StateError('播放窗口连接已关闭'), StackTrace.current);
    await _release('subscription', () async {
      try {
        await _childSubscription?.cancel();
      } finally {
        _childSubscription = null;
      }
    });
    await _release('socket', () async {
      await _childSocket?.close().timeout(const Duration(seconds: 3));
    });
  }

  Future<void> watchPlayerWindow() async {
    WindowsUpdateExit.setHandler(onWindowClose);
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
  }

  bool _sendChild(Map<String, dynamic> message) {
    if (_childSocket?.readyState != WebSocket.open) return false;
    try {
      _childSocket!.add(jsonEncode(message));
      return true;
    } catch (error, stackTrace) {
      _reportFailure('send', error, stackTrace);
      return false;
    }
  }

  Future<void> _handleDiagnosticControl(Map<String, dynamic> message) async {
    var success = false;
    try {
      if (message['action'] == 'pause') {
        await Diagnostics.instance.pauseWrites();
      } else if (message['action'] == 'clear') {
        await Diagnostics.instance.clearPausedRecords();
      } else if (message['action'] == 'resume') {
        Diagnostics.instance.resumeWrites();
        await Diagnostics.instance.flushLocal();
      } else {
        throw StateError('未知诊断协调操作');
      }
      success = true;
    } catch (_) {
      // 协调失败通过应答交给主窗口展示，随后由恢复流程解除暂停。
    } finally {
      _sendChild({
        'type': 'diagnosticControlResult',
        'id': message['id'],
        'success': success,
      });
    }
  }

  Future<void> pauseWindowDiagnostics() async {
    _diagnosticsResumed = Completer<void>();
    await _diagnosticCoordinator.pause();
  }

  Future<void> clearWindowDiagnostics() => _diagnosticCoordinator.clear();

  Future<void> resumeWindowDiagnostics() async {
    try {
      await _diagnosticCoordinator.resume();
    } finally {
      _diagnosticsResumed?.complete();
      _diagnosticsResumed = null;
    }
  }

  void syncDiagnosticSettings() {
    final message = jsonEncode({
      'type': 'diagnosticSettings',
      'settings': Diagnostics.instance.settings,
    });
    for (final window in _windows.values) {
      if (window.socket?.readyState == WebSocket.open) {
        window.socket!.add(message);
      }
    }
  }

  Future<void> applyDiagnosticSettings([Map<String, dynamic>? incoming]) async {
    if (incoming != null) _diagnosticSettings = incoming;
    final settings = _diagnosticSettings;
    if (settings == null) return;
    await Diagnostics.instance.configure(
      level: DiagnosticLogLevel.parse(settings['level'] as String?),
      playerLevel: DiagnosticLogLevel.parse(settings['playerLevel'] as String?),
      tracing: settings['tracing'] as bool,
      intervalMs: settings['intervalMs'] as int,
    );
  }

  bool sendDiagnosticRecord(Map<String, Object?> record) {
    return _sendChild({'type': 'diagnostic', 'record': record});
  }

  Future<void> flushDiagnostics() async {
    if (_childSocket?.readyState != WebSocket.open) return;
    final id = ++_flushSequence;
    final request = _flushRequests[id] = Completer<void>();
    try {
      final flushed = request.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          Diagnostics.instance.log(
            DiagnosticLogLevel.warning,
            'window',
            '等待主窗口确认日志写入超时',
          );
        },
      );
      if (!_sendChild({'type': 'diagnosticFlush', 'id': id})) {
        request.completeError(StateError('主窗口连接已关闭'));
      }
      await flushed;
    } finally {
      _flushRequests.remove(id);
    }
  }

  Future<void> showPlayerWindow() =>
      _showPlayerWindow ??= _presentPlayerWindow();

  Future<void> _presentPlayerWindow() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {
      _showPlayerWindow = null;
      rethrow;
    }
  }

  Future<void> playerReady() async {
    await showPlayerWindow();
    if (!_sendChild({'type': 'ready'})) throw StateError('主窗口连接已关闭');
  }

  bool playerFailed() => _sendChild({'type': 'failed'});
  void savePlaybackProgress(int cid, int position) =>
      _sendChild({'type': 'progress', 'cid': cid, 'position': position});

  Future<void> arrange(DesktopPlaybackLayout layout) async {
    if (_childSocket != null) {
      if (!_sendChild({'type': 'arrange', 'layout': layout.name})) {
        throw StateError('主窗口连接已关闭');
      }
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
    if (_childSocket != null) {
      if (_childSocket?.readyState == WebSocket.open) {
        _sendChild({'type': 'solo'});
      } else {
        await setLocalMuted?.call(false);
      }
    } else {
      await _solo(null);
    }
  }

  Future<void> _solo(_PlaybackWindow? target) async {
    void ensureTarget() {
      if (target != null &&
          (!identical(_windows[target.id], target) ||
              target.socket?.readyState != WebSocket.open)) {
        throw StateError('播放窗口连接已关闭');
      }
    }

    ensureTarget();
    final version = ++_soundVersion;
    _soundWindow = target;
    final change = _soundChange.then((_) async {
      if (version != _soundVersion || _shutdown != null) return;
      ensureTarget();
      await setLocalMuted?.call(target != null);
      if (version != _soundVersion || _shutdown != null) return;
      ensureTarget();
      for (final window in _windows.values) {
        if (window.socket?.readyState == WebSocket.open) {
          window.socket!.add(
            jsonEncode({'type': 'mute', 'muted': !identical(window, target)}),
          );
        }
      }
    });
    // 当前请求仍向调用方交付异常，后续声音切换继续使用未失败的队尾。
    _soundChange = change.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    await change;
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
    if (_closing) return;
    _boundsTimer?.cancel();
    _boundsTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_release('bounds', _saveCurrentBounds));
    });
  }

  Future<void> _saveCurrentBounds() async {
    if (await windowManager.isMinimized() ||
        await windowManager.isFullScreen()) {
      return;
    }
    final bounds = await windowManager.getBounds();
    if (_closing) return;
    if (_childSocket?.readyState == WebSocket.open) {
      _childSocket!.add(
        jsonEncode({'type': 'bounds', 'bounds': _rectValues(bounds)}),
      );
    }
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
    // 每个释放阶段独立报告失败，窗口查询或日志失败不能跳过播放器销毁。
    Future<void> release(String phase, Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        Diagnostics.instance.log(
          DiagnosticLogLevel.error,
          'window',
          '关闭播放窗口时清理失败: $phase',
          details: error.runtimeType.toString(),
          stack: stackTrace,
        );
      }
    }

    await release('bounds', () async {
      if (!await windowManager.isMinimized() &&
          !await windowManager.isFullScreen()) {
        final bounds = await windowManager.getBounds();
        if (_childSocket?.readyState != WebSocket.open) return;
        _childSocket!.add(
          jsonEncode({'type': 'bounds', 'bounds': _rectValues(bounds)}),
        );
      }
    });
    await release('player', () async {
      await onPlayerClose?.call();
    });
    await release('diagnostics', () async {
      await Diagnostics.instance.flush().timeout(const Duration(seconds: 3));
    });
    await disconnectPlayer();
    windowManager.removeListener(this);
    WindowsUpdateExit.setHandler(null);
    await windowManager.destroy();
  }
}
