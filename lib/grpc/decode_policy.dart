import 'dart:typed_data';

/// 压缩后的包很小也可能包含大量弹幕。gzip 的尾部记录解压长度，
/// 这里只把它作为调度提示，实际格式校验仍交给解压和 protobuf 解析器。
abstract final class GrpcDecodePolicy {
  static const isolateSize = 256 * 1024;

  static bool shouldUseIsolate(Uint8List data) {
    if (data.length > isolateSize) return true;
    if (data.length < 5 || data[0] != 1) return false;
    final frameLength = ByteData.sublistView(
      data,
      1,
      5,
    ).getUint32(0, Endian.big);
    if (frameLength < 18 || frameLength > data.length - 5) return false;
    const start = 5;
    if (data[start] != 0x1f || data[start + 1] != 0x8b) return false;
    final end = start + frameLength;
    final expandedLength = ByteData.sublistView(
      data,
      end - 4,
      end,
    ).getUint32(0, Endian.little);
    return expandedLength > isolateSize;
  }
}
