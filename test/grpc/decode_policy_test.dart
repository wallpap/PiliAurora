import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/decode_policy.dart';
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/services/danmaku/work_quota.dart';
import 'package:pili_aurora/pages/danmaku/element_size.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/merge.dart';

Uint8List _frame(Uint8List bytes, {bool compressed = false}) {
  final payload = compressed ? const GZipEncoder().encodeBytes(bytes) : bytes;
  return Uint8List(5 + payload.length)
    ..[0] = compressed ? 1 : 0
    ..buffer.asByteData(1, 4).setUint32(0, payload.length, Endian.big)
    ..setAll(5, payload);
}

void main() {
  test('wire inspection covers known storage and retained unknown fields', () {
    for (final element in [
      DanmakuElem(content: '中文与 emoji 🎉', extra: 'metadata'),
      DanmakuElem.fromBuffer([0xc0, 0x0c, 1, 0xc2, 0x0c, 3, 1, 2, 3]),
      DanmakuElem.fromBuffer([0xd8, 1, 127]),
    ]) {
      expect(
        inspectDanmakuProtobuf(element.writeToBuffer(), element: true),
        greaterThanOrEqualTo(estimateDanmakuElementBytes(element)),
      );
    }
  });
  test(
    'six thousand ordinary elements retain room for decode and merge phases',
    () {
      final reply = DmSegMobileReply(
        elems: [
          for (var i = 0; i < 6000; i++)
            DanmakuElem(
              progress: i * 50,
              mode: 1,
              fontsize: 25,
              color: 0xffffff,
              midHash: 'sender-hash',
              content: '正常分段弹幕内容$i',
              idStr: '$i',
              weight: 5,
              pool: 0,
              attr: 0,
              action: '',
            ),
        ],
      );
      final wire = reply.writeToBuffer();
      final decodedStorage = inspectDanmakuProtobuf(wire);
      final retained = 2 * wire.length + 2 * wire.length + decodedStorage;
      expect(
        retained + estimateDanmakuWorkBytes(reply.elems),
        lessThan(DanmakuWorkQuota.instance.maxBytes),
      );
    },
  );
  test('wire inspection rejects oversized elements and repeated unknown fields before parsing', () {
    final large = DmSegMobileReply(elems: [DanmakuElem(content: 'x' * 65536)])
        .writeToBuffer();
    expect(
      () => inspectDanmakuProtobuf(large),
      throwsA(isA<DanmakuWorkTooLarge>()),
    );
    final unknown = Uint8List.fromList([
      for (var i = 0; i < 129; i++) ...[0xc0, 0x0c, 1],
    ]);
    expect(
      () => inspectDanmakuProtobuf(unknown, element: true),
      throwsA(isA<DanmakuWorkTooLarge>()),
    );
    final unknownBytes = DanmakuElem.fromBuffer([0xc2, 0x0c, 3, 1, 2, 3]);
    expect(
      estimateDanmakuElementBytes(unknownBytes),
      greaterThan(estimateDanmakuElementBytes(DanmakuElem())),
    );
    final valid = DmSegMobileReply(
      elems: [DanmakuElem(content: '测试', extra: 'metadata')],
    ).writeToBuffer();
    expect(
      inspectDanmakuProtobuf(valid),
      greaterThan(
        estimateDanmakuElementBytes(
          DmSegMobileReply.fromBuffer(valid).elems.single,
        ),
      ),
    );
  });
  test('压缩和未压缩输出均在 protobuf 解码前遵守字节预算', () {
    for (final (length, compressed, deniedBudget) in [
      (1024 * 1024, true, 1024),
      (100, false, 99),
    ]) {
      final bytes = Uint8List(length);
      final data = _frame(bytes, compressed: compressed);
      expect(GrpcReq.decompressProtobuf(data, maxDecodedBytes: length), bytes);
      expect(
        () => GrpcReq.decompressProtobuf(data, maxDecodedBytes: deniedBudget),
        throwsA(isA<DanmakuWorkTooLarge>()),
        reason: 'compressed=$compressed, length=$length, budget=$deniedBudget',
      );
    }
  });

  test('调度同时考虑原始和解压体积，小帧留在当前 isolate', () {
    for (final (length, compressed, background) in [
      (100, false, false),
      (100, true, false),
      (1 << 20, false, true),
      (1 << 20, true, true),
    ]) {
      final data = _frame(Uint8List(length), compressed: compressed);
      if (compressed) {
        expect(data.length, lessThan(GrpcDecodePolicy.isolateSize));
      }
      expect(
        GrpcDecodePolicy.shouldUseIsolate(data),
        background,
        reason: 'compressed=$compressed, decodedLength=$length',
      );
    }
  });

  test('truncated and invalid frames cannot break the scheduling decision', () {
    for (var length = 0; length < 24; length++) {
      final data = Uint8List(length);
      if (length > 0) data[0] = 1;
      expect(GrpcDecodePolicy.shouldUseIsolate(data), isFalse);
    }
    final truncated = _frame(Uint8List(1 << 20), compressed: true);
    truncated.buffer.asByteData(1, 4).setUint32(0, 0xffffffff, Endian.big);
    expect(GrpcDecodePolicy.shouldUseIsolate(truncated), isFalse);
  });
}
