import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:brotli/brotli.dart';

abstract final class ResponseBodyDecoder {
  static List<int> decompress(List<int> bytes, String? encoding) =>
      switch (encoding?.trim().toLowerCase()) {
        'gzip' => const GZipDecoder().decodeBytes(bytes),
        'br' => const BrotliDecoder().convert(bytes),
        _ => bytes,
      };

  static bool shouldUseIsolate(Uint8List bytes, String? encoding) {
    const threshold = 50 * 1024;
    if (bytes.length >= threshold) return true;
    switch (encoding?.trim().toLowerCase()) {
      // Brotli 没有可直接读取的解压长度。小包也可能膨胀成大响应。
      case 'br':
        return bytes.isNotEmpty;
      case 'gzip':
        if (bytes.length < 18 || bytes[0] != 0x1f || bytes[1] != 0x8b) {
          return false;
        }
        return ByteData.sublistView(
              bytes,
              bytes.length - 4,
            ).getUint32(0, Endian.little) >=
            threshold;
      default:
        return false;
    }
  }
}
