import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/desktop_playback_request.dart';
import 'package:pili_aurora/services/desktop_playback_windows.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/storage.dart';

class _Process implements Process {
  final exited = Completer<int>();
  Object? killFailure;
  int kills = 0;

  void finish(int code) {
    if (!exited.isCompleted) exited.complete(code);
  }

  @override
  Future<int> get exitCode => exited.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    if (killFailure case final error?) throw error;
    finish(-1);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PlayerPeer {
  _PlayerPeer(this.socket, this.initialization, this.messages);
  final WebSocket socket;
  final Map<String, dynamic> initialization;
  final List<Map<String, dynamic>> messages;

  static Future<_PlayerPeer> connect(
    Map<String, String> environment,
    _Process process, {
    bool finishOnDisconnect = true,
  }) async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${environment['PILIAURORA_WINDOW_PORT']}',
      headers: {
        HttpHeaders.authorizationHeader: environment['PILIAURORA_WINDOW_TOKEN'],
      },
    );
    final initialization = Completer<Map<String, dynamic>>();
    final messages = <Map<String, dynamic>>[];
    socket.listen(
      (data) {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        if (!initialization.isCompleted) {
          initialization.complete(message);
        } else {
          messages.add(message);
          if (message['type'] == 'close') {
            process.finish(0);
            unawaited(socket.close());
          }
        }
      },
      onDone: () {
        if (finishOnDisconnect) process.finish(0);
      },
    );
    return _PlayerPeer(socket, await initialization.future, messages);
  }
}

class _ParentPeer {
  _ParentPeer(this.server);
  final HttpServer server;
  final sockets = <WebSocket>[];
  final accepted = Completer<WebSocket>();
  void Function(WebSocket, Map<String, dynamic>)? onMessage;

  Map<String, String> get environment => {
    'PILIAURORA_WINDOW_PORT': '${server.port}',
    'PILIAURORA_WINDOW_TOKEN': 'synthetic-window-token',
  };

  static Future<_ParentPeer> start({
    Object? Function(int)? initialization,
    bool upgrade = true,
  }) async {
    final peer = _ParentPeer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    peer.server.listen((request) async {
      if (!upgrade) return;
      final socket = await WebSocketTransformer.upgrade(request);
      peer.sockets.add(socket);
      if (!peer.accepted.isCompleted) peer.accepted.complete(socket);
      final data = initialization?.call(peer.sockets.length);
      if (data != null) socket.add(data is String ? data : jsonEncode(data));
      socket.listen((data) {
        peer.onMessage?.call(
          socket,
          jsonDecode(data as String) as Map<String, dynamic>,
        );
      });
    });
    return peer;
  }

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}

Map<String, dynamic> _initialization() => {
  'bounds': [10.0, 20.0, 640.0, 400.0],
  'volume': 0.7,
  'cacheDirectory': Directory.systemTemp.path,
  'request': const DesktopPlaybackRequest.live(1).toJson(),
  'storage': {
    'setting': base64Encode([1, 2, 3]),
  },
};

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final previousHttpOverrides = HttpOverrides.current;
  const native = MethodChannel('window_manager');
  const screen = MethodChannel('dev.leanflutter.plugins/screen_retriever');
  late Directory root;
  setUpAll(() async {
    // 本套回归使用真实回环网络，移除 widget binding 默认的 HTTP 400 替身。
    HttpOverrides.global = null;
    root = await Directory.systemTemp.createTemp('pili-desktop-contract-');
    appSupportDirPath = root.path;
    await GStorage.init();
  });
  tearDownAll(() async {
    await GStorage.close();
    await root.delete(recursive: true);
    HttpOverrides.global = previousHttpOverrides;
  });
  setUp(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      screen,
      (
        call,
      ) async => switch (call.method) {
        'getCursorScreenPoint' => {'dx': 100.0, 'dy': 100.0},
        'getAllDisplays' => {
          'displays': [
            {
              'id': 'primary',
              'size': {'width': 1920.0, 'height': 1080.0},
              'visiblePosition': {'dx': 0.0, 'dy': 0.0},
            },
          ],
        },
        _ => null,
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      native,
      (
        call,
      ) async => call.method == 'isMinimized' ? false : null,
    );
  });
  tearDown(() {
    for (final channel in [native, screen]) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('就绪前退出保留实际退出码，并结束启动 Future', () async {
    final process = _Process()..finish(7);
    final windows = DesktopPlaybackWindows(startProcess: (_) async => process);
    addTearDown(windows.closeAll);
    await expectLater(
      windows.open(const DesktopPlaybackRequest.live(1)),
      throwsA(
        isA<ProcessException>().having((e) => e.errorCode, 'exit code', 7),
      ),
    );
  });

  test('握手错误早于进程启动返回仍沿 open 交付，清理失败不覆盖解析原因', () async {
    final process = _Process()..killFailure = StateError('cleanup failed');
    final logged = Completer<void>();
    final previous = Diagnostics.instance.recentLogs.length;
    void checkLog() {
      if (!logged.isCompleted &&
          Diagnostics.instance.recentLogs.length > previous &&
          Diagnostics.instance.recentLogs.any(
            (record) => record['message'] == '播放窗口操作失败: message',
          )) {
        logged.complete();
      }
    }

    Diagnostics.instance.addListener(checkLog);
    addTearDown(() => Diagnostics.instance.removeListener(checkLog));
    late _PlayerPeer peer;
    final windows = DesktopPlaybackWindows(
      startProcess: (environment) async {
        peer = await _PlayerPeer.connect(environment, process);
        peer.socket.add('{invalid');
        await logged.future.timeout(const Duration(seconds: 3));
        return process;
      },
    );
    addTearDown(windows.closeAll);
    await expectLater(
      windows.open(const DesktopPlaybackRequest.live(1)),
      throwsA(isA<FormatException>()),
    );
    expect(process.kills, 1);
    process.finish(0);
    await windows.closeAll();
    expect(
      Directory(peer.initialization['cacheDirectory'] as String).existsSync(),
      isFalse,
    );
  });

  test('旧尺寸损坏时回退，认证凭证只能使用一次，关闭等待进程缓存清理', () async {
    await GStorage.setting.put('desktopPlaybackWindowBounds', {
      '0': [1, 2],
    });
    final process = _Process();
    late _PlayerPeer peer;
    late Map<String, String> environment;
    final windows = DesktopPlaybackWindows(
      startProcess: (values) async {
        environment = values;
        peer = await _PlayerPeer.connect(values, process);
        peer.socket.add(jsonEncode({'type': 'ready'}));
        return process;
      },
    );
    addTearDown(windows.closeAll);
    await windows.open(const DesktopPlaybackRequest.live(1));
    final bounds = peer.initialization['bounds'] as List;
    expect(bounds, hasLength(4));
    expect(bounds[2], greaterThan(0));
    await expectLater(
      _PlayerPeer.connect(environment, _Process()),
      throwsA(isA<WebSocketException>()),
    );
    final cache = Directory(peer.initialization['cacheDirectory'] as String);
    expect(cache.existsSync(), isTrue);
    await windows.closeAll();
    expect(cache.existsSync(), isFalse);
    expect(await process.exitCode, 0);
  });

  test('同时打开的窗口保留不同 ID', () async {
    final ids = <String>[];
    final windows = DesktopPlaybackWindows(
      startProcess: (environment) async {
        ids.add(environment['PILIAURORA_WINDOW_ID']!);
        final process = _Process();
        final peer = await _PlayerPeer.connect(environment, process);
        peer.socket.add(jsonEncode({'type': 'ready'}));
        return process;
      },
    );
    addTearDown(windows.closeAll);
    await Future.wait([
      windows.open(const DesktopPlaybackRequest.live(1)),
      windows.open(const DesktopPlaybackRequest.live(2)),
    ]);
    expect(ids.toSet(), {'0', '1'});
    await windows.closeAll();
  });

  test('声音归属：旧小窗退出不覆盖新目标，当前声音窗口退出才恢复主声', () async {
    final processes = <_Process>[];
    final peers = <_PlayerPeer>[];
    final muted = <bool>[];
    final windows = DesktopPlaybackWindows(
      startProcess: (environment) async {
        final process = _Process();
        processes.add(process);
        final peer = await _PlayerPeer.connect(environment, process);
        peers.add(peer);
        peer.socket.add(jsonEncode({'type': 'ready'}));
        return process;
      },
    )..setLocalMuted = (value) async => muted.add(value);
    addTearDown(windows.closeAll);
    await windows.open(const DesktopPlaybackRequest.live(1));
    await windows.open(const DesktopPlaybackRequest.live(2));
    processes.first.finish(7);
    await _until(
      () =>
          !Directory(peers.first.initialization['cacheDirectory'] as String)
              .existsSync(),
    );
    expect(muted, [true, true]);
    processes.last.finish(9);
    await _until(() => muted.length == 3);
    expect(muted, [true, true, false]);
  });

  test('声音归属：IPC 断连保留活进程声音归属，进程实际退出才恢复主声', () async {
    final process = _Process();
    late _PlayerPeer peer;
    final muted = <bool>[];
    final windows = DesktopPlaybackWindows(
      startProcess: (environment) async {
        peer = await _PlayerPeer.connect(
          environment,
          process,
          finishOnDisconnect: false,
        );
        peer.socket.add(jsonEncode({'type': 'ready'}));
        return process;
      },
    )..setLocalMuted = (value) async => muted.add(value);
    addTearDown(windows.closeAll);
    await windows.open(const DesktopPlaybackRequest.live(1));
    await peer.socket.close();
    await Future<void>.delayed(Duration.zero);
    expect(process.exited.isCompleted, isFalse);
    expect(muted, [true]);
    process.finish(7);
    await _until(() => muted.length == 2);
    expect(muted, [true, false]);
  });

  test('声音归属：退出状态查询失败不将活进程视为已退出', () async {
    final process = _Process();
    late _PlayerPeer peer;
    final muted = <bool>[];
    final windows = DesktopPlaybackWindows(
      startProcess: (environment) async {
        peer = await _PlayerPeer.connect(
          environment,
          process,
          finishOnDisconnect: false,
        );
        peer.socket.add(jsonEncode({'type': 'ready'}));
        return process;
      },
    )..setLocalMuted = (value) async => muted.add(value);
    addTearDown(windows.closeAll);
    await windows.open(const DesktopPlaybackRequest.live(1));
    process.exited.completeError(StateError('synthetic exit tracking failure'));
    await _until(
      () =>
          !Directory(peer.initialization['cacheDirectory'] as String)
              .existsSync(),
    );
    expect(muted, [true]);
    expect(process.kills, 0);
    expect(
      Diagnostics.instance.recentLogs.any(
        (record) => record['message'] == '播放窗口操作失败: exit',
      ),
      isTrue,
    );
  });

  test('声音归属：排队目标断连后不再静音主窗口', () async {
    final process = _Process();
    _PlayerPeer? peer;
    final restoreStarted = Completer<void>();
    final restored = Completer<void>();
    final muted = <bool>[];
    final windows =
        DesktopPlaybackWindows(
            startProcess: (environment) async {
              peer = await _PlayerPeer.connect(
                environment,
                process,
                finishOnDisconnect: false,
              );
              peer!.socket.add(jsonEncode({'type': 'ready'}));
              return process;
            },
          )
          ..setLocalMuted = (value) async {
            if (!restoreStarted.isCompleted) {
              restoreStarted.complete();
              await restored.future;
            }
            muted.add(value);
          };
    addTearDown(() {
      if (!restored.isCompleted) restored.complete();
      return windows.closeAll();
    });
    final restoring = windows.solo();
    await restoreStarted.future.timeout(const Duration(seconds: 3));
    final opening = expectLater(
      windows.open(const DesktopPlaybackRequest.live(1)),
      throwsA(isA<StateError>()),
    );
    await _until(
      () =>
          peer?.messages.any(
            (message) => message['type'] == 'diagnosticSettings',
          ) ==
          true,
    );
    await peer!.socket.close();
    await Future<void>.delayed(Duration.zero);
    restored.complete();
    await Future.wait([restoring, opening]);
    expect(muted, isNotEmpty);
    expect(muted, everyElement(isFalse));
    expect(process.kills, 1);
  });

  test('声音归属：主声恢复在途时新小窗接管，迟到恢复先排空再落实新目标', () async {
    final restoring = Completer<void>();
    final restored = Completer<void>();
    final processes = <_Process>[];
    final peers = <_PlayerPeer>[];
    final requested = <bool>[];
    final applied = <bool>[];
    final windows =
        DesktopPlaybackWindows(
            startProcess: (environment) async {
              final process = _Process();
              processes.add(process);
              final peer = await _PlayerPeer.connect(environment, process);
              peers.add(peer);
              peer.socket.add(jsonEncode({'type': 'ready'}));
              return process;
            },
          )
          ..setLocalMuted = (value) async {
            requested.add(value);
            if (!value && !restoring.isCompleted) {
              restoring.complete();
              await restored.future;
            }
            applied.add(value);
          };
    addTearDown(() {
      if (!restored.isCompleted) restored.complete();
      return windows.closeAll();
    });
    await windows.open(const DesktopPlaybackRequest.live(1));
    processes.first.finish(7);
    await restoring.future.timeout(const Duration(seconds: 3));
    final opening = windows.open(const DesktopPlaybackRequest.live(2));
    // 收到就绪响应后，新目标才已排入声音队列；连接建立本身不保证这一点。
    await _until(
      () =>
          peers.length == 2 &&
          peers.last.messages.any(
            (message) => message['type'] == 'diagnosticSettings',
          ),
    );
    expect(applied, [true]);
    restored.complete();
    await opening;
    await _until(
      () => peers.last.messages.any((message) => message['type'] == 'mute'),
    );
    expect(requested, [true, false, true]);
    expect(applied, [true, false, true]);
    expect(
      peers.last.messages.where((message) => message['type'] == 'mute'),
      [
        {'type': 'mute', 'muted': false},
      ],
    );
  });

  test('声音归属：静音回调失败不毒化切换队列，下一次打开仍能接管', () async {
    final muted = <bool>[];
    var attempts = 0;
    final windows =
        DesktopPlaybackWindows(
            startProcess: (environment) async {
              final process = _Process();
              final peer = await _PlayerPeer.connect(environment, process);
              peer.socket.add(jsonEncode({'type': 'ready'}));
              return process;
            },
          )
          ..setLocalMuted = (value) async {
            if (attempts++ == 0) throw StateError('synthetic mute failure');
            muted.add(value);
          };
    addTearDown(windows.closeAll);
    await expectLater(
      windows.open(const DesktopPlaybackRequest.live(1)),
      throwsA(isA<StateError>()),
    );
    await _until(() => muted.isNotEmpty);
    expect(muted.last, isFalse);
    await windows.open(const DesktopPlaybackRequest.live(2));
    expect(muted.last, isTrue);
  });

  test('窗口没有就绪时启动超时并终止进程', () async {
    final process = _Process();
    final windows = DesktopPlaybackWindows(
      startProcess: (_) async => process,
      startupTimeout: const Duration(milliseconds: 50),
    );
    addTearDown(windows.closeAll);
    await expectLater(
      windows.open(const DesktopPlaybackRequest.live(1)),
      throwsA(isA<TimeoutException>()),
    );
    expect(process.kills, 1);
  });

  for (final entry in <String, Object>{
    '损坏 JSON': '{invalid',
    '非对象': '[]',
    '无效尺寸': {
      ..._initialization(),
      'bounds': [1, 2, 0, 4],
    },
    '损坏快照': {
      ..._initialization(),
      'storage': {'setting': '?'},
    },
  }.entries) {
    test('子窗口${entry.key}沿连接 Future 返回，失败后释放连接并允许重试', () async {
      final parent = await _ParentPeer.start(
        initialization: (count) => count == 1 ? entry.value : _initialization(),
      );
      addTearDown(parent.close);
      final windows = DesktopPlaybackWindows(environment: parent.environment);
      addTearDown(windows.disconnectPlayer);
      final connecting = windows.connectPlayer();
      expect(identical(windows.connectPlayer(), connecting), isTrue);
      await expectLater(connecting, throwsA(isA<FormatException>()));
      expect(windows.initialBounds, isNull);
      expect(windows.cacheDirectory, isNull);
      final initialization = await windows.connectPlayer();
      expect(initialization.request.arguments, 1);
      expect(initialization.storage['setting'], [1, 2, 3]);
      expect(windows.initialBounds!.width, 640);
      expect(parent.sockets, hasLength(2));
    });
  }

  for (final upgrade in [false, true]) {
    test('子窗口${upgrade ? '初始化数据' : '升级握手'}超时关闭等待中的连接', () async {
      final parent = await _ParentPeer.start(upgrade: upgrade);
      addTearDown(parent.close);
      final windows = DesktopPlaybackWindows(
        environment: parent.environment,
        connectionTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(windows.disconnectPlayer);
      await expectLater(
        windows.connectPlayer(),
        throwsA(isA<TimeoutException>()),
      );
      expect(windows.initialBounds, isNull);
    });
  }

  test('已连接后的坏消息及异步回调失败被记录，后续消息继续交付', () async {
    final parent = await _ParentPeer.start(
      initialization: (_) => _initialization(),
    );
    addTearDown(parent.close);
    final windows = DesktopPlaybackWindows(environment: parent.environment);
    addTearDown(windows.disconnectPlayer);
    final muted = Completer<void>();
    windows.setLocalMuted = (value) async {
      if (!value) throw StateError('synthetic callback failure');
      muted.complete();
    };
    await windows.connectPlayer();
    final socket = await parent.accepted.future;
    socket
      ..add('{invalid')
      ..add(
        jsonEncode({
          'type': 'bounds',
          'bounds': [1, 2],
        }),
      )
      ..add(jsonEncode({'type': 'mute', 'muted': false}))
      ..add(jsonEncode({'type': 'mute', 'muted': true}));
    await muted.future.timeout(const Duration(seconds: 3));
  });

  test('主窗口断连立即结束在途日志刷新，发送结果不误报成功', () async {
    final parent = await _ParentPeer.start(
      initialization: (_) => _initialization(),
    );
    addTearDown(parent.close);
    parent.onMessage = (socket, message) {
      if (message['type'] == 'diagnosticFlush') unawaited(socket.close());
    };
    final windows = DesktopPlaybackWindows(environment: parent.environment);
    addTearDown(windows.disconnectPlayer);
    await windows.connectPlayer();
    await expectLater(windows.flushDiagnostics(), throwsA(isA<StateError>()));
    expect(windows.playerFailed(), isFalse);
    expect(windows.sendDiagnosticRecord({'message': 'synthetic'}), isFalse);
  });

  test('窗口显示失败不缓存失败 Future，下一次能够重新显示', () async {
    var attempts = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
      call,
    ) async {
      if (call.method == 'show' && attempts++ == 0) {
        throw PlatformException(code: 'synthetic_show_failure');
      }
      return call.method == 'isMinimized' ? false : null;
    });
    final windows = DesktopPlaybackWindows();
    await expectLater(
      windows.showPlayerWindow(),
      throwsA(isA<PlatformException>()),
    );
    await windows.showPlayerWindow();
    expect(attempts, 2);
  });
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('等待窗口事件超时');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
