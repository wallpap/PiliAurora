import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// 与 Windows SDK heapapi.h / winnt.h 布局一致，仅用于独立探针。
final class _HeapSummary extends Struct {
  @Uint32()
  external int cb;
  @UintPtr()
  external int allocated;
  @UintPtr()
  external int committed;
  @UintPtr()
  external int reserved;
  @UintPtr()
  external int maxReserve;
}

final class _OptimizeResources extends Struct {
  @Uint32()
  external int version;
  @Uint32()
  external int flags;
}

/// 只查询不可销毁的默认进程堆；不遍历可能被其它线程销毁的私有堆。
/// 这里不包含 Dart VirtualAlloc 堆、全部驱动分配或全部进程 Private。
class ProcessHeapMemory {
  late final _kernel = DynamicLibrary.open('kernel32.dll');
  late final _getHeap = _kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetProcessHeap',
      );
  late final _summary = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<_HeapSummary>),
        int Function(Pointer<Void>, int, Pointer<_HeapSummary>)
      >('HeapSummary');
  late final _setInformation = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<Void>, UintPtr),
        int Function(Pointer<Void>, int, Pointer<Void>, int)
      >('HeapSetInformation');
  late final _lastError = _kernel
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');

  Map<String, Object?> sample() {
    if (!Platform.isWindows) return const {'status': 'unsupported'};
    final summary = calloc<_HeapSummary>();
    try {
      summary.ref.cb = sizeOf<_HeapSummary>();
      if (_summary(_getHeap(), 0, summary) == 0) {
        return {'status': 'error', 'errorCode': _lastError()};
      }
      return {
        'status': 'sampled',
        'scope': 'defaultProcessHeapOnly',
        'allocatedBytes': summary.ref.allocated,
        'committedBytes': summary.ref.committed,
        'reservedBytes': summary.ref.reserved,
        'maxReserveBytes': summary.ref.maxReserve,
      };
    } on ArgumentError {
      return const {'status': 'unsupported'};
    } finally {
      calloc.free(summary);
    }
  }

  /// 单次实验控制，不作为周期策略，也不改变 working set 或 Dart GC。
  Map<String, Object?> optimize() {
    if (!Platform.isWindows) return const {'status': 'unsupported'};
    final info = calloc<_OptimizeResources>();
    try {
      info.ref.version = 1;
      final clock = Stopwatch()..start();
      // HeapOptimizeResources=3；null 表示该进程支持此操作的 heaps。
      final result = _setInformation(
        nullptr,
        3,
        info.cast(),
        sizeOf<_OptimizeResources>(),
      );
      final error = result == 0 ? _lastError() : 0;
      return {
        'status': result == 0 ? 'error' : 'requested',
        'errorCode': error,
        'durationUs': clock.elapsedMicroseconds,
        'semantics': 'allocatorFreePageOptimization; noReleaseGuarantee',
      };
    } on ArgumentError {
      return const {'status': 'unsupported'};
    } finally {
      calloc.free(info);
    }
  }
}
