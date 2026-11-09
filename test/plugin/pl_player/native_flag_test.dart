import 'dart:async';
import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/src/player/native/player/native_flag.dart';

void main() {
  for (final dirtyPadding in [false, true]) {
    for (final value in [false, true]) {
      test('标志 $value 使用完整 C int，尾随非零字节=$dirtyPadding', () async {
        final allocator = _GuardedAllocator(dirtyPadding: dirtyPadding);
        await setMpvFlagProperty('pause', value, (name, format, data) async {
          expect(name, 'pause');
          expect(format, generated.mpv_format.MPV_FORMAT_FLAG);
          // 模拟 C 接口读取完整整数；夹具预留 4 字节，不越界读取。
          expect(data.cast<Int32>().value, value ? 1 : 0);
          expect(allocator.requestedBytes, [sizeOf<Int32>()]);
        }, allocator: allocator);
        expect(allocator.freeCount, 1);
      });
    }
  }

  test('标志读取遵循 C int，忽略紧邻的非零数据', () {
    final data = calloc<Int32>(2);
    addTearDown(() => calloc.free(data));
    data[1] = 0x12345678;
    expect(readMpvFlag(data.cast()), isFalse);
    data[0] = 1;
    expect(readMpvFlag(data.cast()), isTrue);
  });

  for (final fail in [false, true]) {
    test('异步写入${fail ? '失败' : '成功'}前保留参数，结束后只释放一次', () async {
      final allocator = _GuardedAllocator();
      final reply = Completer<void>();
      late Pointer<Void> submitted;
      final result = setMpvFlagProperty('pause', false, (_, _, data) {
        submitted = data;
        return reply.future;
      }, allocator: allocator);
      expect(allocator.freeCount, 0);
      expect(submitted.cast<Int32>().value, 0);
      if (fail) {
        final error = StateError('native write failed');
        final assertion = expectLater(result, throwsA(same(error)));
        reply.completeError(error);
        await assertion;
      } else {
        reply.complete();
        await result;
      }
      expect(allocator.freeCount, 1);
    });
  }

  test('写入同步抛错仍释放参数', () async {
    final allocator = _GuardedAllocator();
    final error = StateError('submission failed');
    await expectLater(
      setMpvFlagProperty('pause', true, (_, _, _) {
        throw error;
      }, allocator: allocator),
      throwsA(same(error)),
    );
    expect(allocator.freeCount, 1);
  });
}

class _GuardedAllocator implements Allocator {
  _GuardedAllocator({this.dirtyPadding = false});

  final bool dirtyPadding;
  final requestedBytes = <int>[];
  var freeCount = 0;

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    requestedBytes.add(byteCount);
    // 只承诺清零请求范围，模拟 Windows 调试堆在分配尾部保留的填充值。
    final capacity = byteCount < 4 ? 4 : byteCount;
    final data = malloc<Uint8>(capacity);
    data.asTypedList(capacity).fillRange(0, capacity, dirtyPadding ? 0xab : 0);
    data.asTypedList(byteCount).fillRange(0, byteCount, 0);
    return data.cast();
  }

  @override
  void free(Pointer pointer) {
    freeCount++;
    malloc.free(pointer);
  }
}
