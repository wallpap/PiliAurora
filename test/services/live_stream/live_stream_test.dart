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
      await live.init();
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

  test(
    'closing before connection setup finishes closes the late connection',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final disconnected = Completer<void>();
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((_) {}, onDone: disconnected.complete);
      });
      final live = LiveMessageStream(
        streamToken: 'synthetic-test-token',
        roomId: 1,
        uid: 0,
        servers: ['ws://127.0.0.1:${server.port}'],
      );
      try {
        final initializing = live.init();
        live.close();
        await initializing;
        await disconnected.future.timeout(const Duration(seconds: 5));
      } finally {
        live.close();
        await server.close(force: true);
      }
    },
  );
}
