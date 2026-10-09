import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 批量写入降低密集 mpv 日志的 I/O 成本；队列同时限制条数和字节。
class DiagnosticRecordStore {
  DiagnosticRecordStore(
    this.file, {
    this.maxBytes = 8 << 20,
    this.retainedFiles = 4,
    this.maxPending = 32768,
    this.maxPendingBytes = 32 << 20,
    this.maxRecordBytes = 1 << 20,
  }) : assert(maxBytes > 0),
       assert(retainedFiles > 0),
       assert(maxPending > 0),
       assert(maxPendingBytes > 0);

  final File file;
  final int maxBytes;
  final int retainedFiles;
  final int maxPending;
  final int maxPendingBytes;
  final int maxRecordBytes;
  final _queue = Queue<List<int>>();
  Future<void> _tail = Future.value();
  bool _scheduled = false;
  int _pending = 0;
  int _pendingBytes = 0;
  int dropped = 0;
  int rotations = 0;
  int evictedFiles = 0;
  int evictedBytes = 0;
  final dropReasons = <String, int>{};
  String? lastError;
  Map<String, Object?>? lastFailure;

  Map<String, Object?> get status => {
    'maxFileBytes': maxBytes,
    'retainedFiles': retainedFiles,
    'pendingRecords': _pending,
    'pendingBytes': _pendingBytes,
    'dropped': dropped,
    'dropReasons': Map.of(dropReasons),
    'rotations': rotations,
    'evictedFiles': evictedFiles,
    'evictedBytes': evictedBytes,
    'lastError': lastError,
    'lastFailure': lastFailure,
  };

  void _drop(String reason, [int count = 1]) {
    dropped += count;
    dropReasons.update(reason, (value) => value + count, ifAbsent: () => count);
  }

  bool add(Map<String, Object?> record) {
    final bytes = utf8.encode('${jsonEncode(record)}\n');
    if (bytes.length > maxBytes || bytes.length > maxRecordBytes) {
      _drop('record-too-large');
      return false;
    }
    if (_pending >= maxPending ||
        _pendingBytes + bytes.length > maxPendingBytes) {
      _drop('queue-full');
      return false;
    }
    _queue.add(bytes);
    _pending++;
    _pendingBytes += bytes.length;
    if (!_scheduled) {
      _scheduled = true;
      _tail = _tail.then((_) => _drain());
    }
    return true;
  }

  Future<void> _drain() async {
    try {
      while (_queue.isNotEmpty) {
        final batch = BytesBuilder(copy: false);
        var count = 0;
        final batchLimit = maxBytes < (1 << 20) ? maxBytes : 1 << 20;
        do {
          batch.add(_queue.removeFirst());
          count++;
        } while (_queue.isNotEmpty &&
            batch.length + _queue.first.length <= batchLimit);
        final bytes = batch.takeBytes();
        try {
          await file.parent.create(recursive: true);
          if (file.existsSync() &&
              await file.length() + bytes.length > maxBytes) {
            for (var i = retainedFiles - 1; i >= 0; i--) {
              final source = File(i == 0 ? file.path : '${file.path}.$i');
              if (!source.existsSync()) continue;
              if (i == retainedFiles - 1) {
                evictedBytes += await source.length();
                evictedFiles++;
                await source.delete();
              } else {
                await source.rename('${file.path}.${i + 1}');
              }
            }
            rotations++;
          }
          await file.writeAsBytes(bytes, mode: FileMode.append, flush: false);
          lastError = null;
        } catch (error) {
          _drop('write-failed', count);
          // 不经日志模块报告磁盘失败，避免递归；导出清单保留故障类型。
          lastError = error.runtimeType.toString();
          lastFailure = {
            'time': DateTime.now().toUtc().toIso8601String(),
            'type': lastError,
            if (error is FileSystemException)
              'osErrorCode': error.osError?.errorCode,
            if (error is FileSystemException)
              'osErrorMessage': error.osError?.message,
          };
        } finally {
          _pending -= count;
          _pendingBytes -= bytes.length;
        }
      }
    } finally {
      _scheduled = false;
    }
  }

  Future<void> flush() => _tail;

  Future<List<File>> files() async {
    await flush();
    return [
      for (var i = 0; i < retainedFiles; i++)
        if (File(i == 0 ? file.path : '${file.path}.$i').existsSync())
          File(i == 0 ? file.path : '${file.path}.$i'),
    ];
  }

  Future<void> clear() {
    final clearing = _tail.then((_) async {
      for (var i = 0; i < retainedFiles; i++) {
        final target = File(i == 0 ? file.path : '${file.path}.$i');
        if (target.existsSync()) await target.delete();
      }
      dropped = rotations = evictedFiles = evictedBytes = 0;
      dropReasons.clear();
      lastError = null;
      lastFailure = null;
    });
    _tail = clearing.catchError((Object error) {
      lastError = error.runtimeType.toString();
    });
    return clearing;
  }

  Future<List<String>> snapshot(Directory destination) {
    final result = Completer<List<String>>();
    _tail = _tail.then((_) async {
      try {
        await destination.create(recursive: true);
        final paths = <String>[];
        for (var i = 0; i < retainedFiles; i++) {
          final source = File(i == 0 ? file.path : '${file.path}.$i');
          if (source.existsSync()) {
            final name = source.uri.pathSegments.last;
            final copy = await source.copy('${destination.path}/$name');
            paths.add(copy.path);
          }
        }
        result.complete(paths);
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }
}
