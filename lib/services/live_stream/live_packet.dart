import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:brotli/brotli.dart';

class PackageHeader {
  const PackageHeader({
    required this.protocolVer,
    required this.operationCode,
    required this.seq,
  });
  final int protocolVer;
  final int operationCode;
  final int seq;

  Uint8List toBytes(int contentSize) {
    final bytes = ByteData(16)
      ..setUint32(0, 16 + contentSize, Endian.big)
      ..setUint16(4, 16, Endian.big)
      ..setUint16(6, protocolVer, Endian.big)
      ..setUint32(8, operationCode, Endian.big)
      ..setUint32(12, seq, Endian.big);
    return bytes.buffer.asUint8List();
  }

  @override
  String toString() =>
      'PackageHeader{protocolVer: $protocolVer, operationCode: $operationCode, seq: $seq}';
}

class PackageHeaderRes extends PackageHeader {
  PackageHeaderRes({
    required this.totalSize,
    required this.headerSize,
    required super.protocolVer,
    required super.operationCode,
    required super.seq,
  });
  final int totalSize;
  final int headerSize;

  static PackageHeaderRes? fromBytesData(Uint8List data, [int offset = 0]) {
    if (offset < 0 || data.length - offset < 16) return null;
    final bytes = ByteData.sublistView(data, offset);
    final totalSize = bytes.getUint32(0, Endian.big);
    final headerSize = bytes.getUint16(4, Endian.big);
    if (headerSize < 16 ||
        totalSize < headerSize ||
        totalSize > data.length - offset) {
      return null;
    }
    return PackageHeaderRes(
      totalSize: totalSize,
      headerSize: headerSize,
      protocolVer: bytes.getUint16(6, Endian.big),
      operationCode: bytes.getUint32(8, Endian.big),
      seq: bytes.getUint32(12, Endian.big),
    );
  }

  @override
  String toString() =>
      'PackageHeaderRes{totalSize: $totalSize, headerSize: $headerSize, protocolVer: $protocolVer, operationCode: $operationCode, seq: $seq}';
}

class DecodedLivePacket {
  const DecodedLivePacket(this.operationCode, this.body);
  final int operationCode;
  final Object? body;
}

class _Cursor {
  _Cursor(this.bytes);
  final Uint8List bytes;
  int offset = 0;
}

/// 使用游标栈处理压缩嵌套包，保持原顺序且不依赖子包数量递归。
List<DecodedLivePacket> decodeLivePackets(Uint8List data) {
  final packets = <DecodedLivePacket>[];
  final stack = [_Cursor(data)];
  while (stack.isNotEmpty) {
    final cursor = stack.last;
    final header = PackageHeaderRes.fromBytesData(cursor.bytes, cursor.offset);
    if (header == null) {
      stack.removeLast();
      continue;
    }
    final body = Uint8List.sublistView(
      cursor.bytes,
      cursor.offset + header.headerSize,
      cursor.offset + header.totalSize,
    );
    cursor.offset += header.totalSize;
    if (header.operationCode == 3) continue;
    try {
      switch (header.protocolVer) {
        case 0:
        case 1:
          if (header.operationCode == 5 || header.operationCode == 8) {
            packets.add(
              DecodedLivePacket(
                header.operationCode,
                body.isEmpty ? null : jsonDecode(utf8.decode(body)),
              ),
            );
          }
        case 2:
        case 3:
          if (stack.length >= 8) continue;
          final expanded = header.protocolVer == 2
              ? ZLibDecoder().convert(body)
              : const BrotliDecoder().convert(body);
          stack.add(
            _Cursor(
              expanded is Uint8List ? expanded : Uint8List.fromList(expanded),
            ),
          );
      }
    } catch (_) {
      // 单包损坏不应丢弃同一帧内后续边界合法的消息。
    }
  }
  return packets;
}
