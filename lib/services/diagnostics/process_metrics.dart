import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class _MemoryCounters extends Struct {
  @Uint32()
  external int cb;
  @Uint32()
  external int faults;
  @UintPtr()
  external int peakWorking;
  @UintPtr()
  external int working;
  @UintPtr()
  external int peakPaged;
  @UintPtr()
  external int paged;
  @UintPtr()
  external int peakNonPaged;
  @UintPtr()
  external int nonPaged;
  @UintPtr()
  external int pagefile;
  @UintPtr()
  external int peakPagefile;
  @UintPtr()
  external int privateBytes;
}

/// Windows 直接读取本进程计数器，不启动 PowerShell 子进程。
class ProcessMetrics {
  final _clock = Stopwatch()..start();
  int? _previousCpu;
  int? _previousElapsed;

  void reset() {
    _previousCpu = _previousElapsed = null;
  }

  late final _kernel = DynamicLibrary.open('kernel32.dll');
  late final _memory = _kernel
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<_MemoryCounters>, Uint32),
        int Function(int, Pointer<_MemoryCounters>, int)
      >('K32GetProcessMemoryInfo');
  late final _times = _kernel
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        ),
        int Function(
          int,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        )
      >('GetProcessTimes');

  Map<String, Object?> sample() {
    final result = <String, Object?>{
      'rssBytes': null,
      'peakRssBytes': null,
      'privateBytes': null,
      'cpuPercentOneCore': null,
      'cpuPercentMachine': null,
      'processorCount': Platform.numberOfProcessors,
    };
    try {
      result['rssBytes'] = ProcessInfo.currentRss;
      result['peakRssBytes'] = ProcessInfo.maxRss;
    } catch (_) {
      // 平台不提供的字段留空。
    }
    if (!Platform.isWindows) return result;
    final memory = calloc<_MemoryCounters>();
    final times = calloc<Uint64>(4);
    try {
      memory.ref.cb = sizeOf<_MemoryCounters>();
      if (_memory(-1, memory, sizeOf<_MemoryCounters>()) != 0) {
        result.addAll({
          'rssBytes': memory.ref.working,
          'peakRssBytes': memory.ref.peakWorking,
          'privateBytes': memory.ref.privateBytes,
        });
      }
      if (_times(-1, times, times + 1, times + 2, times + 3) != 0) {
        final cpu = (times[2] + times[3]) ~/ 10;
        final elapsed = _clock.elapsedMicroseconds;
        if (_previousCpu != null && elapsed > _previousElapsed!) {
          final percent =
              100 * (cpu - _previousCpu!) / (elapsed - _previousElapsed!);
          result['cpuPercentOneCore'] = percent;
          result['cpuPercentMachine'] = percent / Platform.numberOfProcessors;
        }
        _previousCpu = cpu;
        _previousElapsed = elapsed;
      }
    } catch (_) {
      // 系统接口不可用时仍保留 RSS，并将不可测量的指标留空。
    } finally {
      calloc
        ..free(memory)
        ..free(times);
    }
    return result;
  }
}
