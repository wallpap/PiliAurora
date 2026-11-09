import 'dart:ffi';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;

/// MPV_FORMAT_FLAG 的存储类型是 C int，不能按 Dart Bool 或单字节读取。
bool readMpvFlag(Pointer<Void> data) => data.cast<Int32>().value != 0;

Future<void> setMpvFlagProperty(
  String name,
  bool value,
  Future<void> Function(String, int, Pointer<Void>) setProperty, {
  Allocator allocator = calloc,
}) async {
  final ptr = allocator<Int32>(1)..value = value ? 1 : 0;
  try {
    await setProperty(name, generated.mpv_format.MPV_FORMAT_FLAG, ptr.cast());
  } finally {
    allocator.free(ptr);
  }
}
