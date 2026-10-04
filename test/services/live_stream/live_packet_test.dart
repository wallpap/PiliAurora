import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/live_stream/live_packet.dart';
import 'package:pili_aurora/services/live_stream/live_packet_decoder.dart';

Uint8List _packet(List<int> body, {int version = 0, int operation = 5}) =>
    Uint8List.fromList([
      ...PackageHeader(
        protocolVer: version,
        operationCode: operation,
        seq: 1,
      ).toBytes(body.length),
      ...body,
    ]);

Uint8List _message(int id) =>
    _packet(utf8.encode('{"cmd":"DANMU_MSG","id":$id}'));

// .NET BrotliStream 生成的固定包；展开后是 id=3 的合法直播消息。
const _brotliMessage = [
  139,
  20,
  128,
  0,
  0,
  0,
  42,
  0,
  16,
  0,
  0,
  0,
  0,
  0,
  5,
  0,
  0,
  0,
  1,
  123,
  34,
  99,
  109,
  100,
  34,
  58,
  34,
  68,
  65,
  78,
  77,
  85,
  95,
  77,
  83,
  71,
  34,
  44,
  34,
  105,
  100,
  34,
  58,
  51,
  125,
  3,
];

List<int> _ids(List<DecodedLivePacket> packets) => packets
    .where((packet) => packet.operationCode == 5)
    .map((packet) => (packet.body as Map)['id'] as int)
    .toList();

void main() {
  test('mixed plain, zlib and Brotli packets preserve wire order', () {
    final data = Uint8List.fromList([
      ..._message(1),
      ..._packet(ZLibEncoder().convert(_message(2)), version: 2),
      ..._packet(_brotliMessage, version: 3),
      ..._message(4),
    ]);
    expect(_ids(decodeLivePackets(data)), [1, 2, 3, 4]);
  });

  test('large batches do not depend on recursive call depth', () {
    final builder = BytesBuilder(copy: false);
    for (var i = 0; i < 20000; i++) {
      builder.add(_message(i));
    }
    final result = decodeLivePackets(builder.takeBytes());
    expect(result, hasLength(20000));
    expect((result.first.body as Map)['id'], 0);
    expect((result.last.body as Map)['id'], 19999);
  });

  test(
    'extended headers, authentication and heartbeat packets are handled',
    () {
      final extended = _packet([0, 0, 0, 0, ...utf8.encode('{"id":8}')]);
      extended.buffer.asByteData().setUint16(4, 20, Endian.big);
      final result = decodeLivePackets(
        Uint8List.fromList([
          ..._packet([0, 0, 0, 1], version: 1, operation: 3),
          ..._packet(utf8.encode('{"code":0}'), version: 1, operation: 8),
          ...extended,
        ]),
      );
      expect(result.map((packet) => packet.operationCode), [8, 5]);
      expect(result.first.body, {'code': 0});
      expect(_ids(result), [8]);
    },
  );

  test('invalid packet boundaries terminate without exceptions or loops', () {
    for (var length = 0; length < 16; length++) {
      expect(decodeLivePackets(Uint8List(length)), isEmpty);
      expect(PackageHeaderRes.fromBytesData(Uint8List(length)), isNull);
    }
    for (final (field, value) in [(0, 0), (0, 0xffffffff), (4, 1)]) {
      final data = _message(1);
      if (field == 0) {
        data.buffer.asByteData().setUint32(field, value, Endian.big);
      } else {
        data.buffer.asByteData().setUint16(field, value, Endian.big);
      }
      expect(decodeLivePackets(data), isEmpty);
    }
  });

  test('damaged JSON, compressed payloads and unknown versions do not drop later packets', () {
    expect(
      _ids(
        decodeLivePackets(
          Uint8List.fromList([
            ..._packet(utf8.encode('{broken')),
            ..._packet([1, 2, 3], version: 2),
            ..._packet([1, 2, 3], version: 3),
            ..._packet([1, 2, 3], version: 99),
            ..._message(7),
          ]),
        ),
      ),
      [7],
    );
  });

  test('persistent decoder processes multiple requests in order', () async {
    final decoder = LivePacketDecoder();
    addTearDown(decoder.close);
    final results = await Future.wait([
      for (var i = 0; i < 20; i++) decoder.decode(_message(i)),
    ]);
    expect(
      results.map((packets) => _ids(packets).single),
      List.generate(20, (i) => i),
    );
    expect(_ids(await decoder.decode(_packet(_brotliMessage, version: 3))), [
      3,
    ]);
  });

  test(
    'close during startup settles requests and rejects later work',
    () async {
      final decoder = LivePacketDecoder();
      final task = decoder.decode(_message(1));
      final failure = expectLater(task, throwsStateError);
      decoder.close();
      await failure;
      await expectLater(decoder.decode(_message(2)), throwsStateError);
      decoder.close();
    },
  );

  test('close settles work already sent to the worker', () async {
    final decoder = LivePacketDecoder();
    await decoder.decode(_message(0));
    final task = decoder.decode(
      Uint8List.fromList(
        List.generate(10000, (_) => _message(1)).expand((e) => e).toList(),
      ),
    );
    final failure = expectLater(task, throwsStateError);
    // decode 的启动 Future 已完成；等待一个微任务让请求进入 worker 队列。
    await Future<void>.value();
    decoder.close();
    await failure;
  });
}
