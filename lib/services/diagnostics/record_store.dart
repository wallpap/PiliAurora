import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 有界写入队列和轮转文件，诊断不能反过来耗尽内存或磁盘。
class DiagnosticRecordStore {
  DiagnosticRecordStore(
    this.file, {
    this.maxBytes = 2 << 20,
    this.retainedFiles = 3,
    this.maxPending = 256,
  });

  final File file;
  final int maxBytes;
  final int retainedFiles;
  final int maxPending;
  Future<void> _tail = Future.value();
  int _pending = 0;
  int dropped = 0;
  String? lastError;

  bool add(Map<String, Object?> record) {
    if (_pending >= maxPending) {
      dropped++;
      return false;
    }
    final bytes = utf8.encode('${jsonEncode(record)}\n');
    if (bytes.length > maxBytes || bytes.length > 65536) {
      dropped++;
      return false;
    }
    _pending++;
    _tail = _tail
        .then((_) async {
          await file.parent.create(recursive: true);
          if (file.existsSync() &&
              await file.length() + bytes.length > maxBytes) {
            for (var i = retainedFiles - 1; i >= 0; i--) {
              final source = File(i == 0 ? file.path : '${file.path}.$i');
              if (!source.existsSync()) continue;
              if (i == retainedFiles - 1) {
                await source.delete();
              } else {
                await source.rename('${file.path}.${i + 1}');
              }
            }
          }
          await file.writeAsBytes(bytes, mode: FileMode.append, flush: false);
          lastError = null;
        })
        .catchError((Object error) {
          dropped++;
          // 不再调用日志模块，避免磁盘错误导致递归记录。
          lastError = error.runtimeType.toString();
        })
        .whenComplete(() => _pending--);
    return true;
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
      dropped = 0;
      lastError = null;
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
