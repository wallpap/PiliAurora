import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/live_stream/live.dart';

Uint8List _packet(String json, {int version = 0, int operation = 5}) {
  final body = utf8.encode(json);
  return Uint8List.fromList([
    ...PackageHeader(
      protocolVer: version,
      operationCode: operation,
      seq: 1,
    ).toBytes(body.length),
    ...body,
  ]);
}

void main() {
  test('websocket authentication, heartbeat, compressed messages and close work together', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<WebSocket>();
    final auth = Completer<Map>();
    final heartbeat = Completer<void>();
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      accepted.complete(socket);
      socket.listen((dynamic data) {
        final bytes = data as List<int>;
        final header = PackageHeaderRes.fromBytesData(
          Uint8List.fromList(bytes),
        )!;
        if (header.operationCode == 7) {
          auth.complete(
            jsonDecode(utf8.decode(bytes.sublist(header.headerSize))) as Map,
          );
          socket.add(_packet('{"code":0}', version: 1, operation: 8));
        } else if (header.operationCode == 2 && !heartbeat.isCompleted) {
          heartbeat.complete();
        }
      });
    });
    final live = LiveMessageStream(
      streamToken: 'synthetic-test-token',
      roomId: 123,
      uid: 456,
      servers: ['ws://127.0.0.1:0', 'ws://127.0.0.1:${server.port}'],
      heartbeatInterval: const Duration(milliseconds: 10),
    );
    WebSocket? socket;
    try {
      final ids = <int>[];
      final delivered = Completer<void>();
      live.addEventListener((obj) {
        if (obj is Map && obj['id'] is int) {
          ids.add(obj['id'] as int);
          if (ids.length == 3) delivered.complete();
        }
      });
      expect(
        (await live.init()).outcome,
        LiveMessageConnectionOutcome.connected,
      );
      socket = await accepted.future.timeout(const Duration(seconds: 5));
      expect(await auth.future.timeout(const Duration(seconds: 5)), {
        'roomid': 123,
        'uid': 456,
        'protover': 3,
        'platform': 'web',
        'type': 2,
        'key': 'synthetic-test-token',
      });
      await heartbeat.future.timeout(const Duration(seconds: 5));
      final inner = Uint8List.fromList([
        ..._packet('{"cmd":"DANMU_MSG","id":1}'),
        ..._packet('{"cmd":"DANMU_MSG","id":2}'),
      ]);
      final compressed = ZLibEncoder().convert(inner);
      socket
        ..add(
          Uint8List.fromList([
            ...const PackageHeader(
              protocolVer: 2,
              operationCode: 5,
              seq: 1,
            ).toBytes(compressed.length),
            ...compressed,
          ]),
        )
        ..add(_packet('{"cmd":"DANMU_MSG","id":3}'));
      await delivered.future.timeout(const Duration(seconds: 5));
      expect(ids, [1, 2, 3]);
      final lateTask = live.onData(_packet('{"cmd":"DANMU_MSG","id":4}'));
      live.close();
      await lateTask;
      await live.onData(_packet('{"cmd":"DANMU_MSG","id":5}'));
      expect(ids, [1, 2, 3]);
    } finally {
      live.close();
      await socket?.close();
      await server.close(force: true);
    }
  });

  test('握手未返回时退出立即结束初始化，不再尝试后备节点', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requested = Completer<void>();
    var requests = 0;
    server.listen((request) {
      requests++;
      if (!requested.isCompleted) requested.complete();
      // 刻意不返回 HTTP 升级响应。
    });
    final live = LiveMessageStream(
      streamToken: 'synthetic-test-token',
      roomId: 1,
      uid: 0,
      servers: List.filled(2, 'ws://127.0.0.1:${server.port}'),
    );
    try {
      final initializing = live.init();
      expect(identical(live.init(), initializing), isTrue);
      await requested.future.timeout(const Duration(seconds: 5));
      live.close();
      expect(
        (await initializing.timeout(const Duration(seconds: 1))).outcome,
        LiveMessageConnectionOutcome.closed,
      );
      await live.init();
      expect(requests, 1);
    } finally {
      live.close();
      await server.close(force: true);
    }
  });

  test('握手超时释放请求并尝试下一节点，认证只发给成功连接', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final authenticated = Completer<void>();
    WebSocket? socket;
    final paths = <String>[];
    server.listen((request) async {
      paths.add(request.uri.path);
      if (request.uri.path == '/stalled') return;
      socket = await WebSocketTransformer.upgrade(request);
      socket!.listen((_) {
        if (!authenticated.isCompleted) authenticated.complete();
        socket!.add(_packet('{"code":0}', version: 1, operation: 8));
      });
    });
    final live = LiveMessageStream(
      streamToken: 'synthetic-test-token',
      roomId: 1,
      uid: 0,
      servers: [
        'ws://127.0.0.1:${server.port}/stalled',
        'ws://127.0.0.1:${server.port}/ready',
      ],
      connectionTimeout: const Duration(milliseconds: 200),
    );
    try {
      expect(
        (await live.init()).outcome,
        LiveMessageConnectionOutcome.connected,
      );
      await authenticated.future.timeout(const Duration(seconds: 5));
      expect(paths, ['/stalled', '/ready']);
    } finally {
      live.close();
      await socket?.close();
      await server.close(force: true);
    }
  });

  test('关闭后初始化不再建立连接', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((_) => requests++);
    final live = LiveMessageStream(
      streamToken: 'synthetic-test-token',
      roomId: 1,
      uid: 0,
      servers: ['ws://127.0.0.1:${server.port}'],
    );
    try {
      live.close();
      expect((await live.init()).outcome, LiveMessageConnectionOutcome.closed);
      expect(requests, 0);
    } finally {
      await server.close(force: true);
    }
  });

  test('全部节点失败返回明确结果并结束连接生命周期', () async {
    final live = LiveMessageStream(
      streamToken: 'synthetic',
      roomId: 1,
      uid: 0,
      servers: [],
    );
    final result = await live.init();
    expect(result.outcome, LiveMessageConnectionOutcome.failed);
    expect(result.message, contains('重试'));
    expect(result.cause, isNotNull);
    expect(live.isActive, isFalse);
  });

  test('所有握手失败时保留实际原因与堆栈', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response.statusCode = HttpStatus.forbidden;
      unawaited(request.response.close());
    });
    final live = LiveMessageStream(
      streamToken: 'synthetic',
      roomId: 1,
      uid: 0,
      servers: ['ws://127.0.0.1:${server.port}'],
    );
    try {
      final result = await live.init();
      expect(result.outcome, LiveMessageConnectionOutcome.failed);
      expect(result.cause, isA<WebSocketException>());
      expect(result.stackTrace, isNotNull);
      expect(live.isActive, isFalse);
    } finally {
      live.close();
      await server.close(force: true);
    }
  });

  for (final reject in [true, false]) {
    test(reject ? '认证拒绝返回失败且不发送心跳' : '认证没有回执时有界返回失败且不发送心跳', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final disconnected = Completer<void>();
      WebSocket? socket;
      var heartbeats = 0;
      server.listen((request) async {
        socket = await WebSocketTransformer.upgrade(request);
        socket!.listen(
          (dynamic bytes) {
            final header = PackageHeaderRes.fromBytesData(
              Uint8List.fromList(bytes as List<int>),
            )!;
            if (header.operationCode == 7 && reject) {
              socket!.add(_packet('{"code":-101}', version: 1, operation: 8));
            }
            if (header.operationCode == 2) heartbeats++;
          },
          onDone: () {
            if (!disconnected.isCompleted) disconnected.complete();
          },
        );
      });
      final live = LiveMessageStream(
        streamToken: 'synthetic',
        roomId: 1,
        uid: 0,
        servers: ['ws://127.0.0.1:${server.port}'],
        authenticationTimeout: reject
            ? const Duration(seconds: 5)
            : const Duration(milliseconds: 200),
        heartbeatInterval: const Duration(milliseconds: 10),
      );
      try {
        final result = await live.init();
        expect(result.outcome, LiveMessageConnectionOutcome.failed);
        expect(result.message, contains(reject ? '认证失败' : '认证超时'));
        if (reject) expect(result.code, -101);
        if (!reject) expect(result.cause, isA<TimeoutException>());
        await disconnected.future.timeout(const Duration(seconds: 5));
        expect(heartbeats, 0);
        expect(live.isActive, isFalse);
      } finally {
        live.close();
        await socket?.close();
        await server.close(force: true);
      }
    });
  }

  test('等待认证期间主动关闭返回 closed', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final authReceived = Completer<void>();
    WebSocket? socket;
    server.listen((request) async {
      socket = await WebSocketTransformer.upgrade(request);
      socket!.listen((_) {
        if (!authReceived.isCompleted) authReceived.complete();
      });
    });
    final live = LiveMessageStream(
      streamToken: 'synthetic',
      roomId: 1,
      uid: 0,
      servers: ['ws://127.0.0.1:${server.port}'],
    );
    try {
      final initializing = live.init();
      await authReceived.future.timeout(const Duration(seconds: 5));
      live.close();
      expect(
        (await initializing.timeout(const Duration(seconds: 1))).outcome,
        LiveMessageConnectionOutcome.closed,
      );
    } finally {
      live.close();
      await socket?.close();
      await server.close(force: true);
    }
  });
}
